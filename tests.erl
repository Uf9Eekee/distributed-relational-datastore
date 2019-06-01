-module(tests).
-compile(export_all).

test_all() ->
  Pid = self(),
  io:format("Pid of test process: ~p~n", [Pid]),

  Root_hash = node:hash(term_to_binary(root)),
  [{Root_tracker_distance, {Root_tracker_Id, Root_tracker_Pid}} | T] = generate_node_list(generate_nodes(5000), Root_hash),
  Root_tracker_Pid ! {store, Root_hash, {node:hash(crypto:strong_rand_bytes(256)), self()}},
  receive
    Message ->
      io:format("Incoming message to test suite: ~p~n", [Message])
  end,


  io:fwrite("Done generating, taking a nap!~n"),
  timer:sleep(1000000),

  io:fwrite("Works! ~n").

generate_bootstrap_list(Nodes, List) ->
if
  Nodes =:= 0 ->
    List;
  true ->
    Random = crypto:strong_rand_bytes(256),
    K = crypto:hash(sha256, Random),
    generate_bootstrap_list(Nodes-1, [K | List])
end.

generate_node_list([H|T], Root_tracker) ->
  {Id, Pid} = H,
  Distance = node:xor_distance(Id, Root_tracker),
  generate_node_list(T, Root_tracker, [{Distance, {Id, Pid}}]).

generate_node_list([], Root_tracker, Nodes) ->
  Sorted = lists:sort(Nodes),
  Nodes;

generate_node_list([H|T], Root_tracker, Nodes) ->
  {Id, Pid} = H,
  Distance = node:xor_distance(Id, Root_tracker),
  generate_node_list(T, Root_tracker, [{Distance, {Id, Pid}} | Nodes]).

print_buckets(Buckets) ->
  [H | T] = Buckets,
  {Index, List} = H,
  Result = [Index, length(List)],
  if
    T == [] -> done;
    true -> print_buckets(T)
  end.

generate_nodes(N) ->
  Id = crypto:hash(sha256, crypto:strong_rand_bytes(32)),
  Pid = spawn(fun() -> node:initialize(Id, [], 20) end),
  io:format("Pid of node ~p: ~p~n",[N, Pid]),
  generate_nodes(N-1, [{Id, Pid}]).

generate_nodes(0, Nodes) ->
  Number_of_nodes = length(Nodes),
  io:format("~p nodes generated.~n", [Number_of_nodes]),
  Nodes;


generate_nodes(N, Nodes) ->
      Id = crypto:hash(sha256, crypto:strong_rand_bytes(32)),
      Pid = spawn(fun() -> node:initialize(Id, lists:sublist(Nodes, 20), 20) end),
      io:format("Pid of node ~p: ~p~n",[N, Pid]),
      generate_nodes(N-1, [{Id, Pid} | Nodes]).