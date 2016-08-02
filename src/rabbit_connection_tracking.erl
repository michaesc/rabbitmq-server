%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_connection_tracking).

%% Abstracts away how tracked connection records are stored
%% and queried.
%%
%% See also:
%%
%%  * rabbit_connection_tracking_handler
%%  * rabbit_reader
%%  * rabbit_event

-export([boot/0,
         ensure_tracked_connections_table_for_node/1,
         ensure_per_vhost_tracked_connections_table_for_node/1,
         ensure_tracked_connections_table_for_this_node/0,
         ensure_per_vhost_tracked_connections_table_for_this_node/0,
         tracked_connection_table_name_for/1, tracked_connection_per_vhost_table_name_for/1,
         clear_tracked_connections_table_for_this_node/0,
         register_connection/1, unregister_connection/1,
         list/0, list/1, list_on_node/1,
         tracked_connection_from_connection_created/1,
         tracked_connection_from_connection_state/1,
         is_over_connection_limit/1, count_connections_in/1]).

-include_lib("rabbit.hrl").

%%
%% API
%%

-spec boot() -> ok.

%% Sets up and resets connection tracking tables for this
%% node.
boot() ->
  ensure_tracked_connections_table_for_this_node(),
  rabbit_log:info("Created a table for connection tracking on this node: ~p",
    [tracked_connection_table_name_for(node())]),
  ensure_per_vhost_tracked_connections_table_for_this_node(),
  rabbit_log:info("Created a table for per-vhost connection counting on this node: ~p",
    [tracked_connection_per_vhost_table_name_for(node())]),
  clear_tracked_connections_table_for_this_node(),
  ok.


-spec ensure_tracked_connections_table_for_this_node() -> ok.

ensure_tracked_connections_table_for_this_node() ->
  ensure_tracked_connections_table_for_node(node()).


-spec ensure_per_vhost_tracked_connections_table_for_this_node() -> ok.

ensure_per_vhost_tracked_connections_table_for_this_node() ->
  ensure_per_vhost_tracked_connections_table_for_node(node()).


-spec ensure_tracked_connections_table_for_node(node()) -> ok.

ensure_tracked_connections_table_for_node(Node) ->
    TableName = tracked_connection_table_name_for(Node),
    case mnesia:create_table(TableName, [{record_name, tracked_connection},
                                       {attributes, [id, node, vhost, name,
                                                     pid, protocol,
                                                     peer_host, peer_port,
                                                     username, connected_at]}]) of
      {atomic, ok} -> ok;
      {aborted, _} -> ok
      %% TODO: propagate errors
    end.


-spec ensure_per_vhost_tracked_connections_table_for_node(node()) -> ok.

ensure_per_vhost_tracked_connections_table_for_node(Node) ->
    TableName = tracked_connection_per_vhost_table_name_for(Node),
    case mnesia:create_table(TableName, [{record_name, tracked_connection_per_vhost},
                                          {attributes, [vhost, connection_count]}]) of
      {atomic, ok} -> ok;
      {aborted, _} -> ok
      %% TODO: propagate errors
    end.


-spec clear_tracked_connections_table_for_this_node() -> ok.

clear_tracked_connections_table_for_this_node() ->
  case mnesia:clear_table(tracked_connection_table_name_for(node())) of
      {atomic, ok} -> ok;
      {aborted, _} -> ok
  end,
  case mnesia:clear_table(tracked_connection_per_vhost_table_name_for(node())) of
      {atomic, ok} -> ok;
      {aborted, _} -> ok
  end.


-spec tracked_connection_table_name_for(node()) -> atom().

tracked_connection_table_name_for(Node) ->
  list_to_atom(rabbit_misc:format("tracked_connection_on_node_~s", [Node])).

-spec tracked_connection_per_vhost_table_name_for(node()) -> atom().

tracked_connection_per_vhost_table_name_for(Node) ->
  list_to_atom(rabbit_misc:format("tracked_connection_per_vhost_on_node_~s", [Node])).


-spec register_connection(rabbit_types:tracked_connection()) -> ok.

register_connection(#tracked_connection{vhost = VHost, id = ConnId, node = Node} = Conn) when Node =:= node() ->
    TableName = tracked_connection_table_name_for(Node),
    PerVhostTableName = tracked_connection_per_vhost_table_name_for(Node),
    rabbit_misc:execute_mnesia_transaction(
      fun() ->
        %% upsert
              case mnesia:dirty_read(TableName, ConnId) of
                  []    ->
                    %% TODO: counter table
                    mnesia:write(TableName, Conn, write),
                    mnesia:dirty_update_counter(
                        PerVhostTableName, VHost, 1);
                  [_Row] ->
                      ok
              end,
              ok
      end).

-spec unregister_connection(rabbit_types:connection_name()) -> ok.

unregister_connection(ConnId = {Node, _Name}) when Node =:= node() ->
    TableName = tracked_connection_table_name_for(Node),
    PerVhostTableName = tracked_connection_per_vhost_table_name_for(Node),
    rabbit_misc:execute_mnesia_transaction(
      fun() ->
              case mnesia:dirty_read(TableName, ConnId) of
                  []     -> ok;
                  [Row] ->
                      mnesia:dirty_update_counter(
                        PerVhostTableName, Row#tracked_connection.vhost, -1),
                      mnesia:delete({TableName, ConnId})
              end
      end).


-spec list() -> [rabbit_types:tracked_connection()].

list() ->
  Chunks = lists:map(
    fun (Node) ->
      Tab = tracked_connection_table_name_for(Node),
      mnesia:dirty_match_object(Tab, #tracked_connection{_ = '_'})
    end, rabbit_mnesia:cluster_nodes(running)),
  lists:foldl(fun(Chunk, Acc) -> Acc ++ Chunk end, [], Chunks).


-spec list(rabbit_types:vhost()) -> [rabbit_types:tracked_connection()].

list(VHost) ->
  Chunks = lists:map(
    fun (Node) ->
      Tab = tracked_connection_table_name_for(Node),
      mnesia:dirty_match_object(Tab, #tracked_connection{vhost = VHost, _ = '_'})
    end, rabbit_mnesia:cluster_nodes(running)),
  lists:foldl(fun(Chunk, Acc) -> Acc ++ Chunk end, [], Chunks).


-spec list_on_node(node()) -> [rabbit_types:tracked_connection()].

list_on_node(Node) ->
  try mnesia:dirty_match_object(
    tracked_connection_table_name_for(Node),
    #tracked_connection{_ = '_'})
  catch exit:{aborted, {no_exists, _}} -> []
  end.

-spec is_over_connection_limit(rabbit_types:vhost()) -> {true, non_neg_integer()} | false.

is_over_connection_limit(VirtualHost) ->
    ConnectionCount = count_connections_in(VirtualHost),
    case rabbit_vhost_limit:connection_limit(VirtualHost) of
        undefined   -> false;
        {ok, Limit} -> case {ConnectionCount, ConnectionCount >= Limit} of
                           %% 0 = no limit
                           {0, _}     -> false;
                           %% the limit hasn't been reached
                           {_, false} -> false;
                           {_N, true} -> {true, Limit}
                       end
    end.


-spec count_connections_in(rabbit_types:vhost()) -> non_neg_integer().

count_connections_in(VirtualHost) ->
    try
      Ns = lists:map(
        fun (Node) ->
          Tab = tracked_connection_per_vhost_table_name_for(Node),
          try
            case mnesia:transaction(
               fun() ->
                 case mnesia:dirty_read({Tab, VirtualHost}) of
                      []    -> 0;
                      [Val] -> Val#tracked_connection_per_vhost.connection_count
                 end
               end) of
                 {atomic,  Val}     -> Val;
                 {aborted, _Reason} -> 0
            end
          catch _ -> 0
          end
        end, rabbit_mnesia:cluster_nodes(running)),
      lists:foldl(fun(X, Acc) -> Acc + X end, 0, Ns)
    catch
        _:Err  ->
            rabbit_log:error(
              "Failed to fetch number of connections in vhost ~p:~n~p~n",
              [VirtualHost, Err]),
            0
    end.

%% Returns a #tracked_connection from connection_created
%% event details.
%%
%% @see rabbit_connection_tracking_handler.
tracked_connection_from_connection_created(EventDetails) ->
    %% Example event:
    %%
    %% [{type,network},
    %%  {pid,<0.329.0>},
    %%  {name,<<"127.0.0.1:60998 -> 127.0.0.1:5672">>},
    %%  {port,5672},
    %%  {peer_port,60998},
    %%  {host,{0,0,0,0,0,65535,32512,1}},
    %%  {peer_host,{0,0,0,0,0,65535,32512,1}},
    %%  {ssl,false},
    %%  {peer_cert_subject,''},
    %%  {peer_cert_issuer,''},
    %%  {peer_cert_validity,''},
    %%  {auth_mechanism,<<"PLAIN">>},
    %%  {ssl_protocol,''},
    %%  {ssl_key_exchange,''},
    %%  {ssl_cipher,''},
    %%  {ssl_hash,''},
    %%  {protocol,{0,9,1}},
    %%  {user,<<"guest">>},
    %%  {vhost,<<"/">>},
    %%  {timeout,14},
    %%  {frame_max,131072},
    %%  {channel_max,65535},
    %%  {client_properties,
    %%      [{<<"capabilities">>,table,
    %%        [{<<"publisher_confirms">>,bool,true},
    %%         {<<"consumer_cancel_notify">>,bool,true},
    %%         {<<"exchange_exchange_bindings">>,bool,true},
    %%         {<<"basic.nack">>,bool,true},
    %%         {<<"connection.blocked">>,bool,true},
    %%         {<<"authentication_failure_close">>,bool,true}]},
    %%       {<<"product">>,longstr,<<"Bunny">>},
    %%       {<<"platform">>,longstr,
    %%        <<"ruby 2.3.0p0 (2015-12-25 revision 53290) [x86_64-darwin15]">>},
    %%       {<<"version">>,longstr,<<"2.3.0.pre">>},
    %%       {<<"information">>,longstr,
    %%        <<"http://rubybunny.info">>}]},
    %%  {connected_at,1453214290847}]
    Name = proplists:get_value(name, EventDetails),
    Node = proplists:get_value(node, EventDetails),
    #tracked_connection{id           = {Node, Name},
                        name         = Name,
                        node         = Node,
                        vhost        = proplists:get_value(vhost, EventDetails),
                        username     = proplists:get_value(user, EventDetails),
                        connected_at = proplists:get_value(connected_at, EventDetails),
                        pid          = proplists:get_value(pid, EventDetails),
                        peer_host    = proplists:get_value(peer_host, EventDetails),
                        peer_port    = proplists:get_value(peer_port, EventDetails)}.

tracked_connection_from_connection_state(#connection{
               vhost = VHost,
               connected_at = Ts,
               peer_host = PeerHost,
               peer_port = PeerPort,
               user = Username,
               name = Name
             }) ->
  tracked_connection_from_connection_created(
    [{name, Name},
     {node, node()},
     {vhost, VHost},
     {user, Username},
     {connected_at, Ts},
     {pid, self()},
     {peer_port, PeerPort},
     {peer_host, PeerHost}]).