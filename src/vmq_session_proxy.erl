%% Copyright 2014 Erlio GmbH Basel Switzerland (http://erl.io)
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(vmq_session_proxy).
-include("vmq_server.hrl").

-behaviour(gen_server).

%% API
-export([start_link/3,
         derefed/2,
         deliver/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {node,
                repl_pid,
                repl_mon,
                queue_pid,
                queue_mon,
                subscriber_id,
                waiting}).

-define(RETRY, 10000). % wait 10 seconds to retry

%%%===================================================================
%%% API
%%%===================================================================

start_link(Node, QPid, SubscriberId) ->
    gen_server:start_link(?MODULE, [Node, QPid, SubscriberId], []).

derefed(SessionProxy, MsgRef) ->
    gen_server:cast(SessionProxy, {derefed, MsgRef}).

deliver(SessionProxy, Term) ->
    %% this must be a call (as well as infinity), this ensures
    %% that the deliver_from_store process is kept alive as long
    %% as there are messages to replicate
    %%
    %% this call lasts as long as the message is not delivered and
    %% acked on the remote node
    %%
    %% SessionProxy is the Pid on either the local or remote node
    gen_server:call(SessionProxy, {deliver, Term}, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Node, QPid, SubscriberId]) ->
    QueueMon = monitor(process, QPid),
    self() ! deliver_from_store, % kick of delivery
    {ok, #state{node=Node, subscriber_id=SubscriberId, queue_pid=QPid,
                queue_mon=QueueMon}}.

handle_call({deliver, Term}, From, State) ->
    {noreply, deliver(From, Term, State)}.

handle_cast({derefed, MsgRef}, #state{waiting={MsgRef, From}} = State) ->
    gen_server:reply(From, ok),
    {noreply, State#state{waiting=undefined}}.

handle_info({'DOWN', MRef, process, Pid, Reason}, State) ->
    #state{repl_pid=ReplPid, repl_mon=ReplMon, queue_mon=QMon,
           subscriber_id=SubscriberId, node=Node} = State,
    case {Pid == ReplPid, Reason} of
        {true, normal} ->
            %% finished replicating
            lager:debug("[~p][~p] stopped message replication for subscriber ~p due to "
                       ++ "deliver_from_store proc stopped normally", [node(), SubscriberId, Node]),
            {stop, normal, State};
        {true, {deliver_from_store, retry}} ->
            case lists:member(Node, vmq_cluster:nodes()) of
                true ->
                    erlang:send_after(?RETRY, self(), deliver_from_store),
                    {noreply, State};
                false ->
                    lager:warning("[~p][~p] stopped due to deliver_from_store proc stopped", [node(), Node]),
                    {stop, normal, State}
            end;
        {true, OtherReason} ->
            lager:warning("replication process for subscriber ~p died due to ~p",
                         [SubscriberId, OtherReason]),
            {stop, OtherReason, State};
        {false, Reason} when QMon == MRef->
            %% session stopped during replication
            demonitor(ReplMon, [flush]),
            exit(ReplPid, normal),
            lager:debug("[~p][~p] stopped message replication for subscriber ~p due to "
                        ++ "session stopped for reason '~p'", [node(), Node, Reason]),
            {stop, Reason, State}
    end;

handle_info(deliver_from_store, #state{node=Node,
                                       subscriber_id=SubscriberId} = State) ->
    Self = self(),
    {ReplPid, ReplMon} =
    case node() of
        Node ->
            spawn_monitor(vmq_msg_store, deliver_from_store,
                          [SubscriberId, Self]);
        _ ->
            spawn_monitor(
              fun() ->
                      case rpc:call(Node, vmq_msg_store, deliver_from_store,
                                    [SubscriberId, Self]) of
                          {badrpc, timeout} ->
                              % maybe netsplit
                              exit({deliver_from_store, retry});
                          {badrpc, {'EXIT', {normal, _}}} ->
                              %% vmq_session_proxy/deliver died
                              exit(normal);
                          {badrpc, {'EXIT', {noproc, _}}} ->
                              %% vmq_session_proxy proc stopped
                              exit(normal);
                          ok -> ok
                      end
              end)
    end,
    {noreply, State#state{repl_pid=ReplPid, repl_mon=ReplMon}}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
deliver(From, Term, State) ->
    #state{queue_pid=QPid, node=Node} = State,
    case Term of
        {RoutingKey, Payload, QoS, Dup, MsgRef} ->
            Msg = #vmq_msg{routing_key=RoutingKey,
                           payload=Payload,
                           dup=Dup,
                           retain=false,
                           qos=QoS, %% TODO: this could be an unwanted
                                    %% QoS upgrade (from the original
                                    %% publisher perspective), the consumer
                                    %% doesn't care.
                           msg_ref={{self(), Node}, MsgRef}},
            enqueue_or_exit(QPid, {deliver, QoS, Msg}),
            State#state{waiting={MsgRef, From}};
        _ ->
            enqueue_or_exit(QPid, {deliver_bin, Term}),
            gen_server:reply(From, ok),
            State
    end.

enqueue_or_exit(QPid, Item) ->
    case vmq_queue:enqueue(QPid, Item) of
        ok ->
            ok;
        {error, _} ->
            %% Session/Queue died, this is ok to happen, we just
            %% have to ensure that we don't reply 'ok' which will
            %% delete the stored msg ref in the remote store.
            exit(normal)
    end.
