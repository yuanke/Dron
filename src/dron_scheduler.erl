-module(dron_scheduler).
-author("Ionel Corneliu Gog").
-include("dron.hrl").
-behaviour(gen_leader).

-export([init/1, handle_call/4, handle_cast/3, handle_info/2,
         handle_leader_call/4, handle_leader_cast/3, handle_DOWN/3,
         elected/3, surrendered/3, from_leader/3, code_change/4, terminate/2,
         create_job_instance/3, create_job_instance/4, run_instance/2,
         ji_succeeded/1, ji_killed/1, ji_timeout/1, ji_failed/2,
         run_job_instance/2, reschedule_job/1]).

-export([start/3, stop/0, schedule/1, unschedule/1]).

-export([take_job/1, job_instance_succeeded/1, job_instance_failed/2,
         job_instance_timeout/1, job_instance_killed/1,
         dependency_satisfied/2, worker_disabled/1,
         store_waiting_job_instance_timer/2,
         store_waiting_job_instance_deps/2, master_coordinator/1]).

-record(state, {leader, leader_node, master_coordinator, worker_policy}).

%===============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% Starts the the scheduler on a list of nodes. One node will be elected as
%% leader. It also receives the name of the master coordinator node.
%%
%% @spec start(Nodes, Master, WorkerPolicy) -> ok
%% @end
%%------------------------------------------------------------------------------
start(Nodes, Master, WorkerPolicy) ->
  gen_leader:start(?MODULE, Nodes, [], ?MODULE, [Master, WorkerPolicy], []).

stop() ->
  gen_leader:leader_call(?MODULE, stop).

%%------------------------------------------------------------------------------
%% @doc
%% @spec schedule(Job) -> ok
%% @end
%%------------------------------------------------------------------------------
schedule(Job) ->
    gen_leader:leader_cast(?MODULE, {schedule, Job}).

%%------------------------------------------------------------------------------
%% @doc
%% @spec unschedule(JobName) -> ok
%% @end
%%------------------------------------------------------------------------------
unschedule(JName) ->
    gen_leader:leader_cast(?MODULE, {unschedule, JName}).

take_job(JName) ->
    gen_leader:leader_cast(?MODULE, {take_job, JName}).

%%------------------------------------------------------------------------------
%% @doc
%% @spec job_instance_succeeded(JobInstanceId) -> ok
%% @end
%%------------------------------------------------------------------------------
job_instance_succeeded(JId) ->
    gen_leader:leader_cast(?MODULE, {succeeded, JId}).

%%------------------------------------------------------------------------------
%% @doc
%% @spec job_instance_failed(JobInstanceId, Reason) -> ok
%% @end
%%------------------------------------------------------------------------------
job_instance_failed(JId, Reason) ->
    gen_leader:leader_cast(?MODULE, {failed, JId, Reason}).

%%------------------------------------------------------------------------------
%% @doc
%% @spec job_instance_timeout(JobInstanceId) -> ok
%% @end
%%------------------------------------------------------------------------------
job_instance_timeout(JId) ->
    gen_leader:leader_cast(?MODULE, {timeout, JId}).

%%------------------------------------------------------------------------------
%% @doc
%% @spec job_instance_killed(JobInstanceId) -> ok
%% @end
%%------------------------------------------------------------------------------
job_instance_killed(JId) ->
    gen_leader:leader_cast(?MODULE, {killed, JId}).

%%------------------------------------------------------------------------------
%% @doc
%% @spec dependency_satisfied(ResourceId, JobInstanceId) -> ok
%% @end
%%------------------------------------------------------------------------------
dependency_satisfied(RId, JId) ->
    gen_leader:leader_cast(?MODULE, {satisfied, RId, JId}).

%%------------------------------------------------------------------------------
%% @doc
%% @spec worker_disabled(JobInstance) -> ok
%% @end
%%------------------------------------------------------------------------------
worker_disabled(JI) ->
    gen_leader:leader_cast(?MODULE, {worker_disabled, JI}).

%%------------------------------------------------------------------------------
%% @doc
%% @spec store_waiting_job_instance_timer(JobInstanceId, WaitTimerRef) -> ok
%% @end
%%------------------------------------------------------------------------------
store_waiting_job_instance_timer(JId, TRef) ->
    gen_leader:cast(?MODULE, {waiting_job_instance_timer, JId, TRef}).

%%------------------------------------------------------------------------------
%% @doc
%% @spec store_waiting_job_instance_deps(JobInstanceId,
%%        UnsatisfiedDependencies) -> ok
%% @end
%%------------------------------------------------------------------------------
store_waiting_job_instance_deps(JId, UnsatisfiedDeps) ->
    gen_leader:leader_cast(?MODULE, {waiting_job_instance_deps, JId,
                                     UnsatisfiedDeps}).

%%------------------------------------------------------------------------------
%% @doc
%% @spec master_coordinator(Node) -> ok
%% @end
%%------------------------------------------------------------------------------
master_coordinator(Node) ->
    gen_leader:leader_cast(?MODULE, {master_coordinator, Node}).

%%------------------------------------------------------------------------------
%% @doc
%% @spec reschedule_job(JId) -> ok
%% @end
%%------------------------------------------------------------------------------
reschedule_job(JId) ->
    gen_leader:leader_cast(?MODULE, {reschedule, JId}).

%===============================================================================
% Internal
%===============================================================================

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
init([Master, WorkerPolicy]) ->
    ets:new(schedule_timers, [named_table]),
    ets:new(start_timers, [named_table]),
    ets:new(wait_timers, [named_table]),
    ets:new(ji_deps, [named_table]),
    ets:new(delay, [public, named_table]),
    {ok, #state{leader_node = undefined, master_coordinator = Master,
                worker_policy = WorkerPolicy}}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Called only in the leader process when it is elected. Sync will be
%% broadcasted to all the nodes in the cluster.
%%
%% @spec elected(State, Election, undefined) -> {ok, Synch, State}
%% @end
%%------------------------------------------------------------------------------
elected(State = #state{master_coordinator = Master, leader_node = LeaderNode,
                       worker_policy = WorkerPolicy}, _Election, undefined) ->
    dron_pool:start_link(Master, WorkerPolicy),
    case LeaderNode of
        undefined ->
            ok;
        _         -> 
            rpc:call(Master, dron_coordinator, new_scheduler_leader,
                     [LeaderNode, node()])
    end,
    {ok, {node(), Master}, State#state{leader = true, leader_node = node()}};

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Called only in the leader process when a new candidate joins the cluster.
%% Sync will be sent to the Node.
%%
%% @spec elected(State, Election, Node) -> {ok, Synch, State}
%% @end
%%------------------------------------------------------------------------------
elected(State, _Election, _Node) ->
    {reply, [], State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Called in all members of the cluster except the leader. Synch is a term
%% returned by the leader in the elected/3 callback.
%%
%% @spec surrendered(State, Synch, Election) -> {ok, State}
%% @end
%%------------------------------------------------------------------------------
surrendered(State, {LeaderNode, Master}, _Election) ->
    {ok, State#state{leader = false, leader_node = LeaderNode,
                     master_coordinator = Master}}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
handle_leader_call(stop, _From, State, _Election) ->
  error_logger:info_msg("Shutting down scheduler ~p", [node()]),
  dron_pool:stop(),
  {stop, shutdown, State}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
handle_leader_cast({schedule, Job = #job{name = JName, start_time = STime,
                                         frequency = Frequency}},
                   State, _Election) ->
    % TODO(ionel): If the process fails while running old instances then
    % some of them may be re-run. Fix it.
    AfterT = run_job_instances_up_to_now(
               Job,
               self(),
               calendar:datetime_to_gregorian_seconds(calendar:local_time()),
               calendar:datetime_to_gregorian_seconds(STime)),
    case Frequency of
      0 -> case AfterT of
             ok -> {ok, State};
             _  -> ets:insert(start_timers,
                      {JName, erlang:send_after(AfterT * 1000, self(),
                                                {run, Job})}),
                   % TODO(ionel): This is potential point of unsynchronization.
                   {ok, State}
           end;
      _ -> ets:insert(start_timers,
                      {JName, erlang:send_after(AfterT * 1000, self(),
                                                {schedule, Job})}),
           {ok, {schedule, Job, AfterT}, State}
    end;
handle_leader_cast({unschedule, JName}, State, _Election) ->
    unschedule_job_inmemory(JName),
    ok = dron_db:archive_job(JName),
    {ok, {unschedule, JName}, State};
handle_leader_cast({take_job, JName}, State, _Election) ->
  RunTime = dron_db:get_last_run_time(JName),
  {ok, Job = #job{frequency = Freq}} = dron_db:get_job(JName),
  STime = calendar:gregorian_seconds_to_datetime(calendar:datetime_to_gregorian_seconds(RunTime) + Freq),
  schedule(Job#job{start_time = STime}),
  {noreply, State};
% A failing leader can potentially take down many processes that are running
% ji_succeeded,ji_failed... Fix it.
handle_leader_cast({succeeded, JId}, State, _Election) ->
    erlang:spawn_link(?MODULE, ji_succeeded, [JId]),
    {noreply, State};
handle_leader_cast({failed, JId, Reason}, State, _Election) ->
    error_logger:error_msg("~p failed with ~p", [JId, Reason]),
    erlang:spawn_link(?MODULE, ji_failed, [JId, true]),
    {noreply, State};
handle_leader_cast({timeout, JId}, State, _Election) ->
    erlang:spawn_link(?MODULE, ji_timeout, [JId]),
    {noreply, State};
handle_leader_cast({killed, JId}, State, _Election) ->
    erlang:spawn_link(?MODULE, ji_killed, [JId]),
    {noreply, State};
handle_leader_cast({satisfied, RId, JId}, State, _Election) ->
    satisfied_dependency(RId, JId, true),
    {ok, {satisfied, RId, JId}, State};
handle_leader_cast({worker_disabled, JI}, State, _Election) ->
    erlang:spawn_link(?MODULE, run_job_instance, [JI, true]),
    {ok, {worker_disabled, JI}, State};
handle_leader_cast({waiting_job_instance_deps, JId, UnsatisfiedDeps}, State,
                   _Election) ->
    ets:insert(ji_deps, {JId, UnsatisfiedDeps}),
    {ok, {waiting_job_instance_deps, JId, UnsatisfiedDeps}, State};
handle_leader_cast({master_coordinator, Master}, State, _Election) ->
    dron_pool:master_coordinator(Master),
    {ok, {master_coordinator, Master},
     State#state{master_coordinator = Master}};
handle_leader_cast({reschedule, {Name, Date}}, State, _Election) ->
    {ok, Job} = dron_db:get_job(Name),
    AfterT = run_job_instances_up_to_now(
               Job, self(),
               calendar:datetime_to_gregorian_seconds(calendar:local_time()),
               calendar:datetime_to_gregorian_seconds(Date)),
    ets:insert(start_timers,
               {Name, erlang:send_after(AfterT * 1000, self(),
                                        {schedule, Job})}),
    {ok, {schedule, Job, AfterT}, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Handling messages from leader.
%%
%% @spec from_leader(Request, State, Election) ->
%%                                     {ok, State} |
%%                                     {noreply, State} |
%%                                     {stop, Reason, State}
%% @end
%%------------------------------------------------------------------------------
from_leader({schedule, Job = #job{name = JName}, AfterT}, State, _Election) ->
  ets:insert(start_timers, {JName, erlang:send_after(AfterT * 1000, self(),
                                                     {schedule, Job})}),
  {ok, State};
from_leader({unschedule, JName}, State, _Election) ->
  unschedule_job_inmemory(JName),
  {ok, State};
from_leader({satisfied, RId, JId}, State, _Election) ->
  satisfied_dependency(RId, JId, false),
  {ok, State};
from_leader({worker_disabled, JI}, State, _Election) ->
  erlang:spawn_link(?MODULE, run_job_instance, [JI, false]),
  {ok, State};
from_leader({waiting_job_instance_deps, JId, UnsatisfiedDeps}, State,
            _Election) ->
  ets:insert(ji_deps, {JId, UnsatisfiedDeps}),
  {ok, State};
from_leader({master_coordinator, Master}, State, _Election) ->
  {ok, State#state{master_coordinator = Master}};
from_leader(stop, State, _Election) ->
  {stop, shutdown, State}.

%%------------------------------------------------------------------------------
%% @private
%% @doc
%% Handling nodes going down. Called in the leader only.
%%
%% @spec handle_DOWN(Node, State, Election) ->
%%                                  {ok, State} |
%%                                  {ok, Broadcast, State}
%% @end
%%------------------------------------------------------------------------------
handle_DOWN(Node, State, _Election) ->
    error_logger:error_msg("Master node ~p went down", [Node]),
    {ok, State}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
handle_call(Request, _From, State, _Election) ->
    error_logger:error_msg("Got unexpected call ~p", [Request]),
    {stop, not_supported, not_supported, State}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
handle_cast({waiting_job_instance_timer, JId, TRef}, State, _Election) ->
    ets:insert(wait_timers, {JId, TRef}),
    {noreply, State}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
handle_info({schedule, Job = #job{name = JName, frequency = Freq}},
            State = #state{leader = Leader}) ->
  {ok, TRef} = timer:apply_interval(Freq * 1000, ?MODULE, create_job_instance,
                                    [Job, self(), Leader]),
  ets:insert(schedule_timers, {JName, TRef}),
  ets:delete(start_timers, JName),
  {noreply, State};
handle_info({run, Job = #job{name = JName}}, State) ->
  ets:delete(start_timers, JName),
  ets:insert(schedule_timers, {JName, no_timer}),
  create_job_instance(Job, self(), true),
  {noreply, State};
handle_info({wait_timeout, JId}, State) ->
    case ets:lookup(wait_timers, JId) of
        [{JId, TRef}] -> erlang:cancel_timer(TRef),
                         ets:delete(wait_timers, JId);
        []            -> ok
    end,
    {noreply, State};
handle_info({'EXIT', _Pid, normal}, State) ->
    % Linked process finished normally. Ignore the message.
    {noreply, State};
handle_info({'EXIT', PId, Reason}, State) ->
    % TODO(ionel): Handle child process failure.
    error_logger:error_msg("~p anormally finished with ~p", [PId, Reason]),
    {noreply, State}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
code_change(_OldVsn, State, _Election, _Extra) ->
    {ok, State}.

instanciate_dependencies(_JId, []) ->
    {[], []};
instanciate_dependencies(JId, Dependencies) ->
    IDeps = dron_language:instanciate_dependencies(Dependencies),
    case IDeps of 
        [] -> {[], []};
        _  -> {IDeps, dron_db:store_dependant(IDeps, JId)}
    end.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
create_job_instance(Job, SchedulerPid, Leader) ->
  create_job_instance(Job, calendar:local_time(), SchedulerPid, Leader).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
create_job_instance(#job{name = Name, deps_timeout = DepsTimeout,
                         dependencies = Dependencies},
                    Date, SchedulerPid, false) ->
  JId = {Name, Date},  
  case Dependencies of
    [] -> ok;
    _  -> TRef = erlang:send_after(DepsTimeout * 1000, SchedulerPid,
                                   {wait_timeout, JId}),
          dron_scheduler:store_waiting_job_instance_timer(JId, TRef)
  end;
create_job_instance(#job{name = Name, cmd_line = Cmd, timeout = Timeout,
                         deps_timeout = DepsTimeout,
                         dependencies = Dependencies},
                    Date, SchedulerPid, true) ->
  JId = {Name, Date},
  RunTime = calendar:local_time(),
%    Delay = calendar:datetime_to_gregorian_seconds(RunTime) -
%        calendar:datetime_to_gregorian_seconds(Date),
%    MaxDelay = case ets:lookup(delay, delay) of
%                   [{delay, MDelay}] -> MDelay;
%                   []                -> 0
%               end,
%    if Delay > MaxDelay -> ets:insert(delay, {delay, Delay}),
%                           error_logger:info_msg("Max Delay ~p", [Delay]);
%       true             -> ok
%    end,
  {Deps, UnsatisfiedDeps} = instanciate_dependencies(JId, Dependencies),
  JI =  #job_instance{jid = JId, name = Name, cmd_line = Cmd,
                      state = waiting, timeout = Timeout,
                      run_time = RunTime,
                      num_retry = 0,
                      dependencies = Deps,
                      worker = undefined},
  ok = dron_db:store_job_instance(JI),
  % TODO(ionel): Check if the wait_timer is properly inserted in the slave as
  % well.
  case UnsatisfiedDeps of 
    [] -> run_job_instance(JI, true);
    _  -> TRef = erlang:send_after(DepsTimeout * 1000, SchedulerPid,
                                   {wait_timeout, JId}),
          dron_scheduler:store_waiting_job_instance_timer(JId, TRef),
          dron_scheduler:store_waiting_job_instance_deps(
            JId, UnsatisfiedDeps)
  end.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
run_instance(_JId, false) ->
    ok;
run_instance(JId, true) ->
    RunTime = calendar:local_time(),
    error_logger:info_msg("Job Started: ~p at ~p:", [JId, RunTime]),
    {ok, NoWorkerJI = #job_instance{timeout = Timeout}} =
        dron_db:get_job_instance_unsync(JId),
    #worker{name = WName} = get_worker_backoff(),
    JI = NoWorkerJI#job_instance{worker = WName},
    ok = dron_db:store_job_instance(JI),
    dron_worker:run(WName, JI, Timeout).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
run_job_instance(_JI, false) ->
    ok;
run_job_instance(JobInstance = #job_instance{jid = JId,
                                             timeout = Timeout}, true) ->
    RunTime = calendar:local_time(),
    error_logger:info_msg("Job Started: ~p at ~p:", [JId, RunTime]),
    #worker{name = WName} = get_worker_backoff(),
    WorkerJI = JobInstance#job_instance{worker = WName, state = running},
    ok = dron_db:store_job_instance(WorkerJI),
    dron_worker:run(WName, WorkerJI, Timeout).
        
run_job_instances_up_to_now(Job = #job{name = JName, frequency = Frequency},
                            SchedulerPid, Now, STime) ->
    if STime < Now ->
            create_job_instance(
              Job, calendar:gregorian_seconds_to_datetime(STime),
              SchedulerPid, true),
            case Frequency of
              0 -> ets:insert(schedule_timers, {JName, no_timer}),
                   ok;
              _ -> run_job_instances_up_to_now(
                     Job, SchedulerPid,
                     calendar:datetime_to_gregorian_seconds(
                       calendar:local_time()),
                     STime + Frequency)
            end;
       true -> STime - Now
    end.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
satisfied_dependency(RId, JId, Leader) ->
    case ets:lookup(ji_deps, JId) of
        [{JId, RIds}] ->
            case lists:delete(RId, RIds) of
                []  -> case ets:lookup(wait_timers, JId) of
                           [{JId, TRef}] -> erlang:cancel_timer(TRef),
                                            ets:delete(wait_timers, JId);
                           []            -> ok 
                       end,
                       ets:delete(ji_deps, JId),
                       erlang:spawn_link(?MODULE, run_instance, [JId, Leader]);
                Val -> ets:insert(ji_deps, {JId, Val})
            end;
        []            ->
            ok
    end.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
detect_reschedule_job({Name, Date}) ->
    case ets:lookup(schedule_timers, Name) of
        []              -> 
            case ets:lookup(start_timers, Name) of
                [] -> reschedule_job({Name, Date}),
                      true;
                _  -> false
            end;
        [{_JId, _TRef}] -> false
    end.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
call_release_slot(WName, Coord) ->
    case Coord of
        true  -> ok = dron_coordinator:release_slot(WName);
        false -> ok = dron_pool:release_worker_slot(WName)
    end.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
ji_succeeded(JId) ->
    Reschedule = detect_reschedule_job(JId),
    ok = dron_db:set_job_instance_state(JId, succeeded),
    {ok, #job_instance{worker = WName}} = dron_db:get_job_instance_unsync(JId),
    call_release_slot(WName, Reschedule).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
ji_killed(JId) ->
    Reschedule = detect_reschedule_job(JId),
    ok = dron_db:set_job_instance_state(JId, killed),
    {ok, #job_instance{worker = WName}} = dron_db:get_job_instance_unsync(JId),
    call_release_slot(WName, Reschedule).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
ji_timeout(JId) ->
    Reschedule = detect_reschedule_job(JId),
    ok = dron_db:set_job_instance_state(JId, timeout),
    {ok, #job_instance{worker = WName}} = dron_db:get_job_instance_unsync(JId),
    call_release_slot(WName, Reschedule).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
ji_failed(JId, Leader) ->
    Reschedule = detect_reschedule_job(JId),
    {ok, JI = #job_instance{name = JName, worker = WName, num_retry = NumRet}} =
        dron_db:get_job_instance_unsync(JId),
    call_release_slot(WName, Reschedule),
    {ok, #job{max_retries = MaxRet}} = dron_db:get_job_unsync(JName),
    if
        NumRet < MaxRet ->
            run_job_instance(JI#job_instance{num_retry = NumRet + 1}, Leader);
        true            ->
            ok
    end.

unschedule_job_inmemory(JName) ->
    case ets:lookup(start_timers, JName) of
        [{JName, STRef}] -> erlang:cancel_timer(STRef),
                            ets:delete(start_timers, JName);
        []               -> ok
    end,
    case ets:lookup(schedule_timers, JName) of
        [{JName, TRef}]  -> timer:cancel(TRef),
                            ets:delete(schedule_timers, JName);
        []               -> ok
    end.

get_worker_backoff() ->
    get_worker_backoff(dron_config:min_backoff(), dron_config:max_backoff()).

get_worker_backoff(CurBackoff, MaxBackoff) ->
    case dron_pool:get_worker() of
        {error, Error} ->
            if CurBackoff =< MaxBackoff ->
                    timer:sleep(CurBackoff),
                    get_worker_backoff(CurBackoff * 2, MaxBackoff);
               true ->
                    error_logger:info_msg("No slots available on ~p", [node()]),
                    {error, Error}
            end;
        Worker -> Worker
    end.
