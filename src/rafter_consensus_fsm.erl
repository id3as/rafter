-module(rafter_consensus_fsm).

-behaviour(gen_fsm).

-include("rafter.hrl").
-include("rafter_consensus_fsm.hrl").

-define(CLIENT_TIMEOUT, 2000).
-define(ELECTION_TIMEOUT_MIN, 150).
-define(ELECTION_TIMEOUT_MAX, 300).
-define(HEARTBEAT_TIMEOUT, 75).
-define(logname(), logname(State#state.me)).
-define(timeout(), timeout(State#state.timer_start, State#state.timer_duration)).

%% API
-export([start/0, stop/1, start/2, start_link/4, leader/1, op/2, set_config/2,
         send/2, send_sync/2]).

%% gen_fsm callbacks
-export([init/1, code_change/4, handle_event/3, handle_info/3,
         handle_sync_event/4, terminate/3, format_status/2]).

%% States
-export([follower/2, follower/3, candidate/2, candidate/3, leader/2, leader/3]).

%% Testing outputs
-export([set_term/2, candidate_log_up_to_date/4]).

%% This function is simply for testing a single peer with erlang transport
start() ->
    Me = peer1,
    Peers = [peer2, peer3, peer4, peer5],
    start(Me, Peers).

stop(Pid) ->
    gen_fsm:send_all_state_event(Pid, stop).

start(Me, Peers) ->
    gen_fsm:start({local, Me}, ?MODULE, [Me, Peers], []).

start_link(NameAtom, Me, Peers, StateMachine) ->
    gen_fsm:start_link({local, NameAtom}, ?MODULE, [Me, Peers, StateMachine], []).

leader(Peer) ->
    gen_fsm:sync_send_all_state_event(Peer, get_leader, 100).

op(Peer, Command) ->
    gen_fsm:sync_send_event(Peer, {op, Command}).

set_config(Peer, Config) ->
    gen_fsm:sync_send_event(Peer, {set_config, Config}).

-spec send(atom(), #vote{} | #append_entries_rpy{}) -> ok.
send(To, Msg) ->
    gen_fsm:send_event(To, Msg).

-spec send_sync(atom(), #request_vote{} | #append_entries{}) -> 
    {ok, #vote{}} | {ok, #append_entries_rpy{}}. 
send_sync(To, Msg) ->
    Timeout=100,
    gen_fsm:sync_send_event(To, Msg, Timeout).

%%=============================================================================
%% gen_fsm callbacks 
%%=============================================================================

init([Me, Peers, StateMachine]) ->
    random:seed(),
    Duration = election_timeout(),
    State = #state{term=0,
                   peers=Peers,
                   me=Me, 
                   responses=dict:new(),
                   followers=[],
                   timer_start=os:timestamp(),
                   timer_duration = Duration,
                   state_machine=StateMachine},
    {ok, follower, State, Duration}.

format_status(_, [_, State]) ->
    Data = lager:pr(State, ?MODULE),
    [{data, [{"StateData", Data}]}].

handle_event(stop, _, State) ->
    {stop, normal, State};
handle_event(_Event, _StateName, State) ->
    {stop, {error, badmsg}, State}.

handle_sync_event(get_leader, _From, StateName, State) ->
    {reply, State#state.leader, StateName, State, ?timeout()};
handle_sync_event(_Event, _From, _StateName, State) ->
    {stop, badmsg, State}.

handle_info({client_timeout, Id}, StateName, #state{client_reqs=Reqs}=State) ->
    case find_client_req(Id, Reqs) of
        {ok, ClientReq} ->
            send_client_timeout_reply(ClientReq),
            NewState = State#state{client_reqs=delete_client_req(Id, Reqs)},
            {next_state, StateName, NewState, ?timeout()}; 
        not_found ->
            {next_state, StateName, State, ?timeout()}
    end;
handle_info(_, _, State) ->
    {stop, badmsg, State}.

terminate(_, _, _) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) -> 
    {ok, StateName, State}.

%%=============================================================================
%% States
%%
%% Note: All RPC's and client requests get answered in State/3 functions.
%% RPC Responses get handled in State/2 functions.
%%=============================================================================

%% Election timeout has expired. Go to candidate state.
follower(timeout, State) ->
    {next_state, candidate, State, 0};

%% Ignore stale messages.
follower(#vote{}, State) ->
    {next_state, follower, State, ?timeout()};
follower(#append_entries_rpy{}, State) ->
    {next_state, follower, State, ?timeout()}.

%% Vote for this candidate
follower(#request_vote{}=RequestVote, _From, State) ->
    handle_request_vote(RequestVote, State);

follower(#append_entries{term=Term}, _From, 
         #state{term=CurrentTerm, me=Me}=State) when CurrentTerm > Term ->
    Rpy = #append_entries_rpy{from=Me, term=CurrentTerm, success=false},
    {reply, Rpy, follower, State, ?timeout()};
follower(#append_entries{term=Term, from=From, prev_log_index=PrevLogIndex, 
                         entries=Entries, commit_index=CommitIndex}=AppendEntries,
         _From, #state{me=Me, config=C}=State) ->
    Duration = election_timeout(),
    State2=set_term(Term, State),
    State3=State2#state{timer_start=os:timestamp(), timer_duration=Duration},
    Rpy = #append_entries_rpy{term=Term, success=false, from=Me},
    case consistency_check(AppendEntries, State3) of
        false ->
            {reply, Rpy, follower, State3, Duration};
        true ->
            ok = rafter_log:truncate(?logname(), PrevLogIndex),
            {ok, CurrentIndex}  = rafter_log:append(?logname(), Entries),
            Config = maybe_reconfig(C, Entries),
            NewRpy = Rpy#append_entries_rpy{success=true, index=CurrentIndex},
            State4 = commit_entries(CommitIndex, State3),
            State5 = State4#state{leader=From, config=Config},
            {reply, NewRpy, follower, State5, Duration}
    end;

%% Redirect clients to leader.
follower({op, _Command}, _From, #state{leader=undefined}=State) ->
    {reply, {error, election_in_progress}, follower, State, ?timeout()};
follower({op, _Command}, _From, #state{leader=Leader}=State) ->
    Reply = {error, {redirect, Leader}},
    {reply, Reply, follower, State, ?timeout()}.

maybe_reconfig(CurrentConfig, Entries) ->
    lists:foldl(fun(#rafter_entry{type=config}=E, _) ->
                        E;
                    (_, Config) ->
                        Config
                end, CurrentConfig, Entries).
                  

%% The election timeout has elapsed so start an election
candidate(timeout, #state{term=CurrentTerm, me=Me}=State) ->
    Duration = election_timeout(),
    NewTerm = CurrentTerm + 1,
    NewState = State#state{term = NewTerm,
                           responses = dict:new(),
                           timer_duration = Duration,
                           timer_start=os:timestamp(),
                           leader=undefined,
                           voted_for=Me},
    ok = rafter_log:set_current_term(?logname(), NewTerm),
    ok = rafter_log:set_voted_for(?logname(), Me),
    request_votes(NewState),
    {next_state, candidate, NewState, Duration};

%% We are out of date. Go back to follower state. 
candidate(#vote{term=VoteTerm, success=false}, #state{term=Term}=State) 
         when VoteTerm > Term ->
    NewState = step_down(VoteTerm, State),
    {next_state, follower, NewState, NewState#state.timer_duration};

%% This is a stale vote from an old request. Ignore it.
candidate(#vote{term=VoteTerm}, #state{term=CurrentTerm}=State)
          when VoteTerm < CurrentTerm ->
    {next_state, candidate, State, ?timeout()};

candidate(#vote{success=false, from=From}, #state{responses=Responses}=State) ->
    NewResponses = dict:store(From, false, Responses),
    NewState = State#state{responses=NewResponses},
    {next_state, candidate, NewState, ?timeout()};

%% Sweet, someone likes us! Do we have enough votes to get elected?
candidate(#vote{success=true, from=From}, #state{responses=Responses,
                                                 config=Config}=State) ->
    NewResponses = dict:store(From, true, Responses),
    case rafter_config:quorum(Config, NewResponses) of
        true ->
            NewState = become_leader(State),
            {next_state, leader, NewState, 0};
        false ->
            NewState = State#state{responses=NewResponses},
            {next_state, candidate, NewState, ?timeout()}
    end.

%% A Peer is simultaneously trying to become the leader
%% If it has a higher term, step down and become follower.
candidate(#request_vote{term=RequestTerm}=RequestVote, _From, 
          #state{term=Term}=State) when RequestTerm > Term ->
    NewState = step_down(RequestTerm, State),
    handle_request_vote(RequestVote, NewState);
candidate(#request_vote{}, _From, #state{term=CurrentTerm, me=Me}=State) ->
    Vote = #vote{term=CurrentTerm, success=false, from=Me},
    {reply, Vote, candidate, State, ?timeout()};

%% Another peer is asserting itself as leader. If it has a current term
%% step down and become follower. Otherwise do nothing
candidate(#append_entries{term=RequestTerm}, _From, #state{term=CurrentTerm}=State)
        when RequestTerm >= CurrentTerm ->
    NewState = step_down(RequestTerm, State),
    {next_state, follower, NewState, NewState#state.timer_duration};
candidate(#append_entries{}, _From, State) ->
    {next_state, candidate, State, ?timeout()};

%% We are in the middle of an election. 
%% Leader should always be undefined here.
candidate({op, _Command}, _From, #state{leader=undefined}=State) ->
    {reply, {error, election_in_progress}, candidate, State, ?timeout()}.

leader(timeout, State) ->
    Duration = heartbeat_timeout(),
    NewState = State#state{timer_start=os:timestamp(), timer_duration=Duration},
    send_append_entries(State),
    {next_state, leader, NewState, Duration};

%% We are out of date. Go back to follower state.
leader(#append_entries_rpy{term=Term, success=false}, 
       #state{term=CurrentTerm}=State) when Term > CurrentTerm ->
    NewState = step_down(Term, State),
    {next_state, follower, NewState, NewState#state.timer_duration};

%% The follower is not synced yet. Try the previous entry
leader(#append_entries_rpy{from=From, success=false}, 
       #state{followers=Followers}=State) ->
    NextIndex = decrement_follower_index(From, Followers),
    NewState = State#state{followers=dict:store(From, NextIndex, Followers)},
    LastLogIndex = rafter_log:get_last_index(?logname()),
    maybe_send_entry(From, NextIndex, LastLogIndex, NewState),
    {next_state, leader, NewState, ?timeout()};

%% This is a stale reply from an old request. Ignore it.
leader(#append_entries_rpy{term=Term, success=true}, 
       #state{term=CurrentTerm}=State) when CurrentTerm > Term ->
    {next_state, leader, State, ?timeout()};

%% Success!
leader(#append_entries_rpy{from=From, success=true, index=Index},
       #state{followers=Followers, responses=Responses}=State) ->
    case save_responses(dict:find(From, Responses), Index, Responses, From) of
        %% Duplicate Index Received 
        Responses ->
            {next_state, leader, State, ?timeout()};
        NewResponses ->
            State2 = commit(NewResponses, State),
            NextIndex = increment_follower_index(From, Followers),
            State3 = State2#state{
                followers=dict:store(From, NextIndex, Followers),
                responses=NewResponses},
            LastLogIndex = rafter_log:get_last_index(?logname()),
            maybe_send_entry(From, NextIndex, LastLogIndex, State3),
            {next_state, leader, State3, ?timeout()}
    end;

%% Ignore stale votes.
leader(#vote{}, State) ->
    {next_state, leader, State, ?timeout()}.

%% An out of date leader is sending append_entries, tell it to step down.
leader(#append_entries{term=Term}, _From, #state{term=CurrentTerm, me=Me}=State) 
        when Term < CurrentTerm ->
    Rpy = #append_entries_rpy{from=Me, term=CurrentTerm, success=false},
    {reply, Rpy, leader, State, ?timeout()};

%% We are out of date. Step down
leader(#append_entries{term=Term}, _From, #state{term=CurrentTerm}=State) 
        when Term > CurrentTerm ->
    NewState = step_down(Term, State),
    {next_state, follower, NewState, NewState#state.timer_duration};

%% We are out of date. Step down
leader(#request_vote{term=Term}, _From, #state{term=CurrentTerm}=State)
        when Term > CurrentTerm ->
    NewState = step_down(Term, State),
    {next_state, follower, NewState, NewState#state.timer_duration};

%% An out of date candidate is trying to steal our leadership role. Stop it.
leader(#request_vote{}, _From, #state{me=Me, term=CurrentTerm}=State) ->
    Rpy = #vote{from=Me, term=CurrentTerm, success=false},
    {reply, Rpy, leader, State, ?timeout()};

leader({set_config, {Id, NewServers}}, From, #state{term=Term, config=C}=State) ->
    case allow_config(C, NewServers) of
        true ->
            Config = reconfig(C, NewServers),
            Entry = #rafter_entry{type=config, term=Term, cmd=Config},
            NewState = append(Id, From, Entry, State#state{config=Config}),
            {next_state, leader, NewState, ?timeout()};
        false ->
            {reply, {error, config_in_progress}, leader, State, ?timeout()}
    end;

%% Handle client requests
leader({op, {Id, Command }}, From, 
        #state{term=Term}=State) ->
    Entry = #rafter_entry{type=op, term=Term, cmd=Command},
    NewState = append(Id, From, Entry, State),
    {next_state, leader, NewState, ?timeout()}.
    
%%=============================================================================
%% Internal Functions 
%%=============================================================================

-spec reconfig(#config{}, list()) -> #config{}.
reconfig(#config{state=blank}=Config, Servers) ->
    Config#config{state=transitional, newservers=Servers};
reconfig(#config{state=stable}=Config, Servers) ->
    Config#config{state=transitional, newservers=Servers}.

-spec allow_config(#config{}, list()) -> boolean().
allow_config(#config{state=blank}, _NewServers) ->
    true;
allow_config(#config{state=stable, oldservers=OldServers}, NewServers) 
    when NewServers =/= OldServers ->
    true;
allow_config(_Config, _NewServers) ->
    false.

-spec append(binary(), term(), #rafter_entry{}, #state{}) -> #state{}.
append(Id, From, Entry, #state{me=Me, term=Term, client_reqs=Reqs}=State) ->
    {ok, Index} = rafter_log:append(?logname(), [Entry]),
    {ok, Timer} = timer:send_after(?CLIENT_TIMEOUT, Me, {client_timeout, Id}),
    ClientRequest = #client_req{id=Id,
                                from=From, 
                                index=Index, 
                                term=Term, 
                                timer=Timer},
    NewState = State#state{client_reqs=[ClientRequest | Reqs]},

    %% This is not strictly necessary and only improves latency. 
    %% We could just wait for the next heartbeat.
    send_append_entries(State),
    NewState.

send_client_timeout_reply(#client_req{from=From, id=Id}) ->
    gen_fsm:reply(From, {error, timeout, Id}).

send_client_reply(#client_req{from=From, id=Id}, Result) ->
    gen_fsm:reply(From, {ok, Result, Id}).

find_client_req(Id, ClientRequests) ->
    Result = lists:filter(fun(Req) ->
                              Req#client_req.id =:= Id 
                          end, ClientRequests),
    case Result of
        [Request] ->
            {ok, Request};
        [] ->
            not_found
    end.

delete_client_req(Id, ClientRequests) ->
    lists:filter(fun(Req) ->
                     Req#client_req.id =/= Id 
                 end, ClientRequests).

find_client_req_by_index(Index, ClientRequests) ->
    Result = lists:filter(fun(Req) ->
                              Req#client_req.index =:= Index
                          end, ClientRequests),
    case Result of
        [Request] ->
            {ok, Request};
        [] ->
            not_found
    end.

delete_client_req_by_index(Index, ClientRequests) ->
    lists:filter(fun(Req) ->
                    Req#client_req.index =/= Index
                 end, ClientRequests).
                    
%% @doc Commit entries between the previous commit index and the new one.
%%      Apply them to the local state machine and respond to any outstanding
%%      client requests that these commits affect. Return the new state.
-spec commit_entries(non_neg_integer(), #state{}) -> #state{}.
commit_entries(NewCommitIndex, #state{commit_index=CommitIndex, 
                                      state_machine=StateMachine}=State0) ->
   lists:foldl(fun(Index, #state{client_reqs=CliReqs}=State) ->
       NewState = State#state{commit_index=Index},
       case rafter_log:get_entry(?logname(), Index) of

           %% Normal Operation. Apply Command to StateMachine.
           {ok, #rafter_entry{type=op, cmd=Command}} ->
               {ok, Result} = StateMachine:apply(Command),
               maybe_send_client_reply(Index, CliReqs, NewState, Result);

           %% We have a committed transitional state, so reply 
           %% successfully to the client. Then set the new stable
           %% configuration. 
           {ok, #rafter_entry{type=config, 
                   cmd=#config{state=transitional}=C}} ->
               S = stabilize_config(C, NewState),
               maybe_send_client_reply(Index, CliReqs, S, S#state.config);

           %% Nothing left to do. The configuration has already been set.
           {ok, #rafter_entry{type=config,
                   cmd=#config{state=stable}}} ->
               NewState
       end
   end, State0, lists:seq(CommitIndex+1, NewCommitIndex)).

-spec stabilize_config(#config{}, #state{}) -> #state{}.
stabilize_config(#config{state=transitional, newservers=New}=C, #state{term=Term}=S)
    when S#state.leader =:= S#state.me ->
        Config = C#config{state=stable, oldservers=New, newservers=[]},
        Entry = #rafter_entry{type=config, term=Term, cmd=Config},
        State = S#state{config=Config},
        {ok, _Index} = rafter_log:append(?logname(), [Entry]),
        send_append_entries(State),
        State.

-spec maybe_send_client_reply(non_neg_integer(), [#client_req{}], #state{}, 
                              term()) -> #state{}.
maybe_send_client_reply(Index, CliReqs, S, Result) when S#state.leader =:= S#state.me ->
    case find_client_req_by_index(Index, CliReqs) of
        {ok, Req} ->
            send_client_reply(Req, Result),
            Reqs = delete_client_req_by_index(Index, CliReqs),
            S#state{client_reqs=Reqs};
        not_found ->
            S 
    end.

commit(Responses, #state{commit_index=CommitIndex, config=Config}=State) ->
    Min = rafter_config:quorum_min(Config, dict:to_list(Responses)),
    case Min > CommitIndex andalso safe_to_commit(Min, State) of
        true ->
            commit_entries(Min, State);
        false ->
            State
    end.

safe_to_commit(Index, #state{term=CurrentTerm}=State) ->
    CurrentTerm =:= rafter_log:get_term(?logname(), Index).

%% We are about to transition to the follower state. Reset the necessary state.
step_down(NewTerm, State) ->
    ok = rafter_log:set_voted_for(?logname(), undefined),
    ok = rafter_log:set_current_term(?logname(), NewTerm),
    State#state{term=NewTerm,
                responses=dict:new(),
                timer_duration=election_timeout(),
                timer_start=os:timestamp(),
                voted_for=undefined,
                leader=undefined}.

save_responses({ok, LastIndex}, Index, Responses, _From) when LastIndex > Index ->
    Responses;
save_responses({ok, Index}, Index, Responses, _From) ->
    Responses;
save_responses({ok, _LastIndex}, Index, Responses, From) ->
    dict:store(From, Index, Responses);
save_responses(error, Index, Responses, From) ->
    dict:store(From, Index, Responses).

handle_request_vote(#request_vote{from=CandidateId, term=Term}=RequestVote, State) ->
    State2 = set_term(Term, State),
    {ok, Vote} = vote(RequestVote, State2),
    %% TODO:  rafter_log:write(NewState),
    case Vote#vote.success of
        true ->
            ok = rafter_log:set_voted_for(?logname(), CandidateId),
            ok = rafter_log:set_current_term(?logname(), State2#state.term),
            Duration = election_timeout(),
            State3 = State2#state{voted_for=CandidateId, 
                                  timer_duration=Duration, 
                                  timer_start=os:timestamp()},
            {reply, Vote, follower, State3, Duration};
        false ->
            {reply, Vote, follower, State2, ?timeout()}
    end.

maybe_send_entry(_Peer, Index, LastLogIndex, _State) 
        when LastLogIndex < Index ->
    ok;
maybe_send_entry(Peer, Index, LastLogIndex, State)
        when LastLogIndex >= Index ->
    send_entry(Peer, Index, State).

send_entry(Peer, Index, #state{me=Me, term=Term, commit_index=CIdx}=State) ->
    Log = ?logname(),
    {PrevLogIndex, PrevLogTerm} = 
        case Index - 1 of
            0 -> 
                {0, 0};
            PrevIndex ->
                {PrevIndex,
                  rafter_log:get_term(Log, PrevIndex)}
        end,
    Entries = case rafter_log:get_entry(Log, Index) of
                  {ok, not_found} -> 
                      [];
                  {ok, Entry} -> 
                      [Entry]
              end,
    AppendEntries = #append_entries{term=Term,
                                    from=Me,
                                    prev_log_index=PrevLogIndex,
                                    prev_log_term=PrevLogTerm,
                                    entries=Entries,
                                    commit_index=CIdx},
    rafter_requester:send(Peer, AppendEntries).

send_append_entries(#state{followers=Followers}=State) ->
    [send_entry(Peer, Index, State) || {Peer, Index} <- dict:to_list(Followers)].

increment_follower_index(From, Followers) ->
    {ok, Num} = dict:find(From, Followers), 
    Num + 1.

decrement_follower_index(From, Followers) ->
    case dict:find(From, Followers) of
        {ok, 1} ->
            1;
        {ok, Num} ->
            Num - 1
    end.

%% @doc Start a process to send a syncrhonous rpc to each peer. Votes will be sent 
%%      back as messages when the process receives them from the peer. If
%%      there is an error or a timeout no message is sent. This helps preserve
%%      the asynchrnony of the consensus fsm, while maintaining the rpc 
%%      semantics for the request_vote message as described in the raft paper.
request_votes(#state{peers=Peers, term=Term, me=Me}=State) ->
    Log = ?logname(),
    Msg = #request_vote{term=Term,
                        from=Me,
                        last_log_index=rafter_log:get_last_index(Log), 
                        last_log_term=rafter_log:get_last_term(Log)},
    [rafter_requester:send(Peer, Msg) || Peer <- Peers].

become_leader(#state{me=Me}=State) ->
    %% TODO: Commit a noop entry to the log so we can move the commit index
    State#state{leader=Me, 
                responses=dict:new(),
                followers=initialize_followers(State),
                timer_start=os:timestamp()}.

initialize_followers(#state{peers=Peers}=State) ->
    NextIndex = rafter_log:get_last_index(?logname()) + 1,
    Followers = [{Peer, NextIndex} || Peer <- Peers],
    dict:from_list(Followers).

%% There is no entry at t=0, so just return true.
consistency_check(#append_entries{prev_log_index=0, 
                                  prev_log_term=0}, _State) ->
    true;
consistency_check(#append_entries{prev_log_index=Index, 
                                  prev_log_term=Term}, State) ->
    case rafter_log:get_entry(?logname(), Index) of
        {ok, not_found} ->
            false;
        {ok, #rafter_entry{term=Term}} ->
            true;
        {ok, #rafter_entry{term=_DifferentTerm}} ->
            false
    end.

set_term(Term, #state{term=CurrentTerm}=State) when Term < CurrentTerm ->
    State;
set_term(Term, #state{term=CurrentTerm}=State) when Term > CurrentTerm ->
    ok = rafter_log:set_current_term(?logname(), CurrentTerm),
    ok = rafter_log:set_voted_for(?logname(), undefined),
    State#state{term=Term, voted_for=undefined};
set_term(Term, #state{term=Term}=State) ->
    State.

vote(#request_vote{term=Term}, #state{term=CurrentTerm, me=Me}) 
        when Term < CurrentTerm ->
    fail_vote(CurrentTerm, Me);
vote(#request_vote{from=CandidateId, term=CurrentTerm}=RequestVote, 
     #state{voted_for=CandidateId, term=CurrentTerm, me=Me}=State) ->
    maybe_successful_vote(RequestVote, CurrentTerm, Me, State);
vote(#request_vote{term=CurrentTerm}=RequestVote, 
     #state{voted_for=undefined, term=CurrentTerm, me=Me}=State) ->
    maybe_successful_vote(RequestVote, CurrentTerm, Me, State);
vote(#request_vote{from=CandidateId, term=CurrentTerm}, 
     #state{voted_for=AnotherId, term=CurrentTerm, me=Me}) 
     when AnotherId =/= CandidateId ->
    fail_vote(CurrentTerm, Me).

maybe_successful_vote(RequestVote, CurrentTerm, Me, State) ->
    case candidate_log_up_to_date(RequestVote, State) of
        true ->
            successful_vote(CurrentTerm, Me);
        false ->
            fail_vote(CurrentTerm, Me)
    end.

candidate_log_up_to_date(#request_vote{last_log_term=CandidateTerm,
                                       last_log_index=CandidateIndex}, State) ->
    Log = ?logname(),
    candidate_log_up_to_date(CandidateTerm, 
                             CandidateIndex, 
                             rafter_log:get_last_term(Log), 
                             rafter_log:get_last_index(Log)).
            
candidate_log_up_to_date(CandidateTerm, _CandidateIndex, LogTerm, _LogIndex)
    when CandidateTerm > LogTerm ->
        true;
candidate_log_up_to_date(CandidateTerm, _CandidateIndex, LogTerm, _LogIndex)
    when CandidateTerm < LogTerm ->
        false;
candidate_log_up_to_date(Term, CandidateIndex, Term, LogIndex)
    when CandidateIndex > LogIndex ->
        true;
candidate_log_up_to_date(Term, CandidateIndex, Term, LogIndex)
    when CandidateIndex < LogIndex ->
        false;
candidate_log_up_to_date(Term, Index, Term, Index) ->
    true.

successful_vote(CurrentTerm, Me) ->
    {ok, #vote{term=CurrentTerm, success=true, from=Me}}.

fail_vote(CurrentTerm, Me) ->
    {ok, #vote{term=CurrentTerm, success=false, from=Me}}.

logname({Name, _Node}) ->
    list_to_atom(atom_to_list(Name) ++ "_log");
logname(Me) ->
    list_to_atom(atom_to_list(Me) ++ "_log").

timeout(StartTime, Duration) ->
    case Duration - (timer:now_diff(os:timestamp(), StartTime) div 1000) of
        T when T > 0 ->
            T;
        _ ->
            0
    end.

election_timeout() ->
    crypto:rand_uniform(?ELECTION_TIMEOUT_MIN, ?ELECTION_TIMEOUT_MAX).

heartbeat_timeout() ->
    ?HEARTBEAT_TIMEOUT.

%%=============================================================================
%% Tests 
%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-endif.
