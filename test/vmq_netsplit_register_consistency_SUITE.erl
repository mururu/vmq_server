-module(vmq_netsplit_register_consistency_SUITE).
-export([
         %% suite/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0
        ]).

-export([register_consistency_test/1]).

-define(NET_TICK_TIME, 5).

%% ===================================================================
%% common_test callbacks
%% ===================================================================
init_per_suite(_Config) ->
    cover:start(),
    _Config.

end_per_suite(_Config) ->
    _Config.

init_per_testcase(_Case, Config) ->
    Nodes = vmq_netsplit_utils:setup(?NET_TICK_TIME),
    [{nodes, Nodes}|Config].

end_per_testcase(_, Config) ->
    vmq_netsplit_utils:teardown(proplists:get_value(nodes, Config, [])),
    Config.

all() ->
    [register_consistency_test].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Actual Tests
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
register_consistency_test(Config) ->
    Nodes = proplists:get_value(nodes, Config, []),
    ok = vmq_netsplit_utils:check_connected(Nodes),

    %% Create Partitions
    {Island1, Island2} = vmq_netsplit_utils:partition_network(Nodes),

    %%================================%%
    %%     Window of Uncertanity      %%
    %%                                %%
    %% Erlang thinks everything is ok %%
    %%          ..outch..             %%
    %%================================%%

    %% the registration is synchronized using vmq_reg_leader, depending if
    %% we connect to a node sitting in the same partition as the leader we
    %% get disconnected earlier in the registration process.
    PortInIsland1 = vmq_netsplit_utils:get_port(Island1),
    PortInIsland2 = vmq_netsplit_utils:get_port(Island2),

    Connect = packet:gen_connect("test-client", [{clean_session, true},
                                                 {keepalive, 10}]),
    Connack = packet:gen_connack(0),
    {error, closed} = packet:do_client_connect(Connect, Connack,
                                             [{port, PortInIsland1}]),

    {error, closed} = packet:do_client_connect(Connect, Connack,
                                               [{port, PortInIsland2}]),
    vmq_netsplit_utils:fix_network(Island1, Island2),
    ok.
