-module(dron).
-author("Ionel Corneliu Gog").
-include("dron.hrl").
-behaviour(application).

-export([start/0, stop/0]).
-export([start/2, stop/1]).

%===============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @spec start() -> ok | {error, Reason}
%% @end
%%------------------------------------------------------------------------------
start() ->
  application:start(dron).

%%------------------------------------------------------------------------------
%% @doc
%% @spec stop() -> ok | {error, Reason}
%% @end
%%------------------------------------------------------------------------------
stop() ->
  application:stop(dron).

%===============================================================================
% Internal
%===============================================================================

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
start(_Type, _Args) ->
  MnesiaNodes = dron_config:scheduler_nodes() ++
                  dron_config:master_nodes() ++
                  dron_config:db_nodes() ++
                  dron_config:worker_nodes(),
  dron_mnesia:start(dron_config:db_nodes(), [{n_ram_copies, 2}], MnesiaNodes),
  error_logger:info_msg("~nMnesia is running!~n", []),
  {ok, Sup} = dron_sup:start(),
  dron_coordinator:auto_add_sched_workers(),
  {ok, Sup}.
    
%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
stop(_State) ->
  dron_mnesia:stop(),
  ok.
