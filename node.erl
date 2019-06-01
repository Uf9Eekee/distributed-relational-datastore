-module(node).

%% API
-compile(export_all).

%This is the whole node. The base algorithm is pretty much standard Kademlia.

%Id is the address of the node, a sha256 hash.

%Routing_table is a list of tuples like {Index, Nodes}.

%Nodes also a tuple, and looks like {Distance, NodeID}.

%Distance is the XOR distance as defined by the Kademlia
%whitepaper and calculated using xor_distance/2.

%Torrent_data is basically a placeholder for a data structure holding the
%values that are stored on the node. It is a map with the sha256 hash of
%the data as the key, and a list of nodes sharing the data as the value.
%This is pretty much the same as the Bittorrent protocol, although currently
%without support for pieces (which aren't required for testing the metadata).

%Routing_table is the routing table, and can be scrapped and rebuilt
%without anything of value being lost in the long term, while Content is
%supposed to be persistent, even though in reality, this can be rebuilt as
%well, as long as all the underlying content is still being seeded.

%K is a magic Kademlia number that represents several things, like
%the maximum amount of nodes in a bucket, and the (maximum) amount of peers
%to return from a find_node request.


%%Creates the appropriate empty data structures.
initialize(Id, Bootstrap_nodes, K) ->
  Pid = self(),
  Atom = binary_to_atom(Id, latin1),
  register(Atom, Pid),
  Pid = whereis(Atom),
  Routing_table = initialize_buckets(maps:new(), 256),
  Torrent_data = maps:new(),
  Metadata = maps:new(),
  Content = maps:new(),
  bootstrap(Id, Routing_table, Torrent_data, maps:put(hash(term_to_binary(root)), [], Metadata), Content, Bootstrap_nodes, K).

bootstrap(Id, Routing_table, Torrent_data, Metadata, Content, [], K) ->
  Final_buckets = add_node_to_bucket({Id, self()}, Routing_table, Id, K),
  timer:sleep(10000),
  listen(Final_buckets, Torrent_data, Metadata, Content, Id, K);
bootstrap(Id, Routing_table, Torrent_data, Metadata, Content, Bootstrap_nodes, K) ->
  [H | T] = Bootstrap_nodes,
  bootstrap(Id, add_node_to_bucket(H, Routing_table, Id, K), Torrent_data, Metadata, Content, T, K).

download_content(Hash, [{Peer_Id, Peer_Pid}|Peers], Id) ->

  Peer_Pid ! {want, Hash, {Id, self()}},
  receive
    {ack_want, Data, {Id, _}} ->
      Data;
    {ack_want, missing, {Id, _}} ->
      download_content(Hash, Peers, Id)
  after 1000 ->
    download_content(Hash, Peers, Id)

  end;
download_content(Hash, [], Id) ->
  missing.


%%expand_branch() takes the hash of a node, and expands into a branch of all currently known
%%connected nodes in Metadata.
expand_branch(Root_hash, Routing_table, Torrent_data, Metadata, Content, Id, K) ->
  Meta = maps:get(Root_hash, Metadata),
  Children = find_children(Root_hash, [Meta]),
  case Children of
    [] ->
      Content;
    Children ->
      [H|T] = Children,
      case H of
        {parent, Post, Root_hash} ->
          io:format("Trying to expand branch using download_branch~n"),
          New_content = download_content(H, find_closest_nodes(K, Id, H, Routing_table, []), Id),
          {Old_data, Old_content} = maps:take(Root_hash, Content),
          New_content = maps:put(Root_hash, New_content, Content),
          expand_branch(Root_hash, T, Routing_table, Torrent_data, Metadata, New_content, Id, K);
        [] ->
          Content
      end
  end.


expand_branch(Root_hash, [H|T], Routing_table, Torrent_data, Metadata, Content, Id, K) ->
  case H of
    [] ->
      Content;
    {parent, Post, Root_hash}->
      case maps:get(Post, Content, missing) of
        missing ->
          Data = download_content(Root_hash, maps:get(Root_hash, Torrent_data, []), Id),
          New_content = maps:put(Root_hash, Data, Content),
          expand_branch(Root_hash, T, Routing_table, Torrent_data, Metadata, New_content, Id, K);
        Data ->
          expand_branch(Root_hash, T, Routing_table, Torrent_data, Metadata, Content, Id, K)
      end
  end.

get_random_parent(Metadata) ->
  Root_hash = hash(term_to_binary(root)),
  Root_content = maps:get(Root_hash, Metadata),
  case Root_content of
    [] -> Root_hash;
    Root_content ->
      Parent = lists:nth(rand:uniform(length(Root_content)), Root_content),
      {parent, Parent_id, Child_id} = Parent,
      Parent_id

  end.


%%get_random_from_list(List) ->
%%  Random = rand:uniform(),
%%  if
%%    Random > 0.5 and List /= [] ->
%%      get_random_from_list(lists:nth(random:uniform(length(List)), List));
%%    true ->
%%      lists:nth(random:uniform(length(List)), List)
%%  end.

update_metadata(Hash, Routing_table, Torrent_data, Metadata, Content, Id, K) ->
  {Current_meta, New_map} = maps:take(Hash, Metadata),
  Root = hash(term_to_binary(root)),
  Candidate = find_closest_nodes(K, Id, Root, Routing_table),
  {New_routing_table, [{Distance, {Tracker_id, Tracker_pid}}]} = find_closest_nodes(K, Id, Root, Routing_table, Candidate),
  Length = length(Current_meta),
  Self = self(),
  Tracker_pid ! {get_meta, Hash, Length, {Id, Self}},
  receive
    {ack_get_meta, Hash, up_to_date} ->
      {New_routing_table, Metadata};
    {ack_get_meta, Hash, Updated_meta} ->
      {New_routing_table, maps:put(Hash, Updated_meta, New_map)}

  end.


find_children(Root_hash, []) ->
  [];
find_children(Root_hash, [Metadata_head | T]) ->
  case Metadata_head of
    {parent, _, Root_hash} ->
      find_children(Root_hash, T, [Metadata_head]);
    [] ->
      [];
    Metadata_head ->
      find_children(Root_hash, T, [])
  end.

find_children(Root_hash, [], Current_results) ->
  Current_results;

find_children(Root_hash, [H | T], Current_results) ->
  case H of
    {parent, _, Root_hash} ->
      find_children(Root_hash, T, [H | Current_results]);
    [] ->
      Current_results;
    H ->
      find_children(Root_hash, T, Current_results)
  end.



%%This is the resting state of the main loop. Listens to incoming requests and acts on them.
%%Always call listen/5 with the current State, Metadata, Content, Id and K after finishing other tasks.

listen(Routing_table, Torrent_data, Metadata, Content, Id, K) ->
  Wait_time = random:uniform(1000),
  receive
    {ping, {NodeID, Pid}} ->
      %%io:format("Ping received in node ~p!~n", [self()]),
      Pid ! {ack_ping, Id},
      Updated_routing_table = add_node_to_bucket({NodeID, Pid}, Routing_table, Id, K),
      listen(Updated_routing_table, Torrent_data, Metadata, Content, Id, K);

    {get_meta, Hash, Current_meta_hash, {Node_Id, Node_Pid}} ->
      New_meta = maps:get(Hash, Metadata),
      %%io:format("New_meta looks like: ~p~n", [New_meta]),
      New_meta_size = length(New_meta),
      case New_meta_size of
        Current_meta_size ->
          Node_Pid ! {ack_get_meta, Hash, up_to_date};
        New_meta_size ->
          Node_Pid ! {ack_get_meta, Hash, New_meta}
      end;

    {store, Hash, Node} ->
      element(2, Node) ! {ack_store, Hash},
      listen(Routing_table, store(Hash, Torrent_data), Metadata, Content, Id, K);

    {store_meta, Meta, Node} ->
      {Relation, Parent, Child} = Meta,
      {Old_meta, Old_metadata} = maps:take(Parent, Metadata),
      listen(Routing_table, Torrent_data, maps:put(Parent, [Meta | Old_meta], Old_metadata), Content, Id, K);

    {find_related, Hash, Node} ->
      Related = maps:get(Hash, Torrent_data),
      case Related of
        {badkey, Hash} ->
          find_pid(Id, element(1, Node), Routing_table) ! {ack_find_related, Hash, badkey};
        {badmap, Hash} ->
          find_pid(Id, element(1, Node), Routing_table) ! {ack_find_related, Hash, error};
        Related ->
          find_pid(Id, element(1, Node), Routing_table) ! {ack_find_related, Hash, Related}
      end,
      listen(Routing_table, Torrent_data, Metadata, Content, Id, K);

    {get, Hash, Node} ->
      Data = maps:get(Hash, Content),
      find_pid(Id, element(1, Node), Routing_table) ! {ack_get, Hash, Data},
      listen(Routing_table, Torrent_data, Metadata, Content, Id, K);

    {want, Hash, Hash_list, Node} ->
      Payload = maps:get(Hash, Content),
      {Node_Id, Pid} = Node,
      Pid ! {ack_want, Hash, Payload},
      listen(Routing_table, Torrent_data, Metadata, Content, Id, K);

    {have, Hash, Hash_list, Node} ->
      Piece_list = maps:take(Hash, Torrent_data),
      lists:keyreplace(Node, 1, Hash_list, {Node, Piece_list}),
      {NodeID, Pid} = Node,
      listen(Routing_table, maps:put(NodeID, Piece_list, Torrent_data), Metadata, Content, Id, K);

    {store, Hash, Node} ->
      Exists = maps:find(Hash, Torrent_data),
      case Exists of
        error ->
          element(2, Node) ! {ack_store, Hash},
          listen(Routing_table, maps:put(Hash, [Node], Torrent_data), Metadata, Content, Id, K);
        true ->
          Peers = [Node, maps:get(Hash, Torrent_data)],
          element(2, Node) ! {ack_store, Hash},
          listen(Routing_table, maps:put(Hash, Peers, Torrent_data), Metadata, Content, Id, K)
      end;


    {find_value, Hash, Node} ->
      Value = find_value(Hash, Torrent_data),
      if
        {not_available} == Value ->
          find_pid(Id, element(1, Node), Routing_table) ! {Node, ack_find_value, find_closest_nodes(K, Id, Hash, Routing_table)};
        true ->
          find_pid(Id, element(1, Node), Routing_table) ! {Node, ack_find_value, {Hash, Value}}
      end,
      listen(Routing_table, Torrent_data, Metadata, Content, Id, K);

    {find_node, Hash, Node} ->
      {Node_id, Node_pid} = Node,
      Nearest = find_closest_nodes(K, Id, Hash, Routing_table),
      Node_pid ! {ack_find_node, Nearest},
      listen(Routing_table, Torrent_data, Metadata, Content, Id, K);

%%This is the main mechanism of getting the node to do what you want it to do. Should be
%%verified before execution, which right now isn't the case. Very much not for production.
%%This is an invite for anyone to run arbitrary code on your machine. Also, should probably
%%not be done like this in the first place, but it works for rapid testing.
    {Id, execute_query, Query} ->
      {Routing_table, Torrent_data, Content, Id, K} = Query(Routing_table, Torrent_data, Content, Id, K),
      listen(Routing_table, Torrent_data, Metadata, Content, Id, K);

    Request ->
      io:format("Unknown request received! Content: ~p~n", [Request]),
      listen(Routing_table, Torrent_data, Metadata, Content, Id, K)

  after Wait_time ->
    Nodes_to_update = get_nodes_to_update(Routing_table),
    Timeouts = ping(Nodes_to_update),
    New_content = expand_branch(hash(term_to_binary(root)),Routing_table,Torrent_data,Metadata,Content,Id,K),
    case Timeouts of
      [] ->
        {RT, TD, MD, C, I, K} = random_action(Routing_table, Torrent_data, Metadata, New_content, Id, K),
        listen(RT, TD, MD, C, I, K);
      Timeouts ->
        New_routing_table = remove_nodes(Id, Routing_table, Timeouts),
        {RT, TD, MD, C, I, K} = random_action(New_routing_table, Torrent_data, Metadata, New_content, Id, K),
        listen(RT, TD, MD, C, I, K)
    end


  end.

random_action(Routing_table, Torrent_data, Metadata, Content, Id, K) ->
  Rnd = random:uniform(),
  if
    Rnd > 0.95 ->
      {New_routing_table, New_meta} = update_metadata(hash(term_to_binary(root)), Routing_table, Torrent_data, Metadata, Content, Id, K),
      {New_routing_table, Torrent_data, New_meta, Content, Id, K};
    Rnd > 0.90 ->
      {New_content, New_Metadata} = post_new_content(Routing_table, Content, Metadata, Id, K),
      {Routing_table, Torrent_data, Metadata, New_content, Id, K};
    true ->
      {Routing_table, Torrent_data, Metadata, Content, Id, K}
  end.

post_meta(Meta, Routing_table, Metadata, Id, K) ->
  Hash = hash(term_to_binary(Meta)),
  case Meta of
    {parent, Post, Parent} ->
      [{Tracker_Distance, {Tracker_Id, Tracker_Pid}}|T] = find_closest_nodes(K, Id, Parent, Routing_table),
      Tracker_Pid ! {store_meta, Meta, {Id, self()}}
  end,
  maps:put(Hash, Meta, Metadata).

add_local_content(Data, Content) ->
  maps:put(hash(Data), Data, Content).

post_new_content(Routing_table, Content, Metadata, Id, K) ->
  Data = crypto:strong_rand_bytes(16),
  Hash = hash(Data),
  [{Distance, {Tracker_Id, Tracker_Pid}} | T] = find_closest_nodes(K, Id, Hash, Routing_table),
  Tracker_Pid ! {store, Hash, {Id, self()}},
  receive
    {ack_store, Hash} ->
      New_content = maps:put(Hash, Data, Content),
      Parent = get_random_parent(Metadata),
      Meta = {parent, Parent, Hash},
      New_metadata = post_meta(Meta, Routing_table, Metadata, Id, K),
      {New_content, New_metadata};
    {ack_store, Error} ->
      io:format("Error posting new content, message: ~p~n", [Error]),
      io:format("Hash is supposed to be ~p~n", [Hash])
  end.


find_related(Hash, Routing_table, Torrent_data, Metadata, Content, Id, K) ->
  [{Tracker_Id, Tracker_Pid} | T] = find_closest_nodes(K, Id, Hash, Routing_table),
  Tracker_Pid ! {find_related, Hash, {Id, self()}},
  receive
    {ack_find_related, Hash, error} ->
      error;
    {ack_find_related, Hash, Values} ->
      {Old_values, Old_content} = maps:take(Hash, Content),
      {Routing_table, Torrent_data, Metadata, maps:put(Hash, Values, Old_content), Id, K}
  end.

%%Sends a ping message to Node, waits for the return message and acts on the result.
extend_routing_table(Id, K, Routing_table) ->
  case maps:next(Routing_table) of
    {_, [], New_iterator} ->
      extend_routing_table(Id, K, New_iterator);
    {_, Nodes, New_iterator} ->
      [H | T] = Nodes,
      {_, Node} = H,
      New_buckets = add_nodes_to_bucket(find_closest_nodes(K, Id, Node, Routing_table), Routing_table, Id, K),
      extend_routing_table(Id, K - 1, New_buckets);
    none ->
      io:fwrite("Routing table extended")
  end.

%%Ping takes a single hash of a node, or a list of tuples of nodes, and pings the node or nodes.
%%When this is done, it returns a list of the nodes that timed out. RTT can be collected, but
%%currently isn't used for anything, and thus not returned.
ping([{Distance, Node} | T]) ->
  Result = ping(Node),
  case Result of
    timeout_error ->
      {Node_Id, Node_Pid} = Node,
      ping(T, [Node_Id]);
    pong -> ping(T);
    ok -> ping(T)
  end;

ping({Id, Pid}) ->
  Self = self(),
  case Pid of
    Self ->
      pong;
    Pid ->
      Pid ! {ping, {Id, self()}},
      receive
        {ack_ping, Id} ->
          %%io:format("Pong received in ~p!~n", [self()]),
          pong
      end
  end;


ping([]) ->
  [].

ping([{Distance, Node} | T], Timeouts) ->
  Result = ping(Node),
  case Result of
    timeout_error ->
      ping(T, [Node | Timeouts]);
    pong ->
      ping(T, Timeouts)
  end;

ping([], Timeouts) ->
  Timeouts.


get_nodes_to_update(Routing_table) ->
  Bucket = maps:get(0, Routing_table),
  case Bucket of
    [] -> get_nodes_to_update(Routing_table, 1, []);
    [{Distance, Node} | T] -> get_nodes_to_update(Routing_table, 1, [{Distance, Node}])
  end.

%Index 256 is the last index, and can only contain the Id of the current node, which is obviously
%alive and well, and therefore not pinged. This only returns the list of nodes to ping.
get_nodes_to_update(Routing_table, 256, Nodes) ->
  Nodes;

get_nodes_to_update(Routing_table, Index, Nodes) ->
  Bucket = maps:get(Index, Routing_table),

  case Bucket of
    [] -> get_nodes_to_update(Routing_table, Index + 1, Nodes);
    [{Distance, Node} | T] ->
      get_nodes_to_update(Routing_table, Index + 1, [{Distance, Node} | Nodes])
  end.

%%remove_nodes takes Id, Routing_table, and a list of nodes to be removed (currently because they timed out
%%during a ping attempt), removes them, and returns the updated routing table. Currently not all that
%%efficiently.
remove_nodes(Id, Routing_table, []) ->
  Routing_table;

remove_nodes(Id, Routing_table, [{Distance, {Node_Id, Node_Pid}} | T]) ->
  BucketIndex = find_closest_bucket(Node_Id, Id),
  {Bucket, _Old_buckets} = maps:take(BucketIndex, Routing_table),
  New_bucket = lists:delete({Distance, Node_Id}, Bucket),
  New_routing_table = maps:put(BucketIndex, New_bucket, Routing_table),
  remove_nodes(Id, New_routing_table, T);

remove_nodes(Id, Routing_table, [{Node_Id, Node_Pid} | T]) ->
  BucketIndex = find_closest_bucket(Node_Id, Id),
  {Bucket, _Old_buckets} = maps:take(BucketIndex, Routing_table),
  New_bucket = lists:delete({xor_distance(Node_Id, Id), Node_Id}, Bucket),
  New_routing_table = maps:put(BucketIndex, New_bucket, Routing_table),
  remove_nodes(Id, New_routing_table, T);

remove_nodes(Id, Routing_table, [Node_Id | T]) ->
  BucketIndex = find_closest_bucket(Node_Id, Id),
  {Bucket, _Old_buckets} = maps:take(BucketIndex, Routing_table),
  New_bucket = lists:delete({xor_distance(Id, Node_Id), Node_Id}, Bucket),
  New_routing_table = maps:put(BucketIndex, New_bucket, Routing_table),
  remove_nodes(Id, New_routing_table, T).



%%Hashes Data using sha256, returns the hash. Not necessary, but might make the code
%%a bit prettier, and makes changing the hashing algorithm easier.
hash(Data) ->
  crypto:hash(sha256, Data).

%%Stores routing data on the node.
%%TODO: Error handling?
store(Payload, Torrent_data) ->
  Hash = hash(Payload),
  maps:put(Hash, Payload, Torrent_data).

find_pid(Id, Node_Id, Nodes) ->
  if
    is_map(Nodes) ->
      Index = find_closest_bucket(Node_Id, Id),
      Bucket = maps:get(Index, Nodes),
      find_pid(Id, Node_Id, Bucket);
    Nodes == [] ->
      no_such_node;
    true ->
      [{Distance,{New_Id, Pid}} | T] = Nodes,
      if
        New_Id == Id -> Pid;
        true -> find_pid(Id, Node_Id, T)
      end

  end.

add_nodes_to_bucket([], Routing_table, Id, K) ->
  Routing_table;
add_nodes_to_bucket(Nodes, Routing_table, Id, K) ->
  [H | T] = Nodes,

  New_buckets = add_node_to_bucket(H, Routing_table, Id, K),
  add_nodes_to_bucket(T, lists:keymerge(1, New_buckets, Routing_table), Id, K).

download(Hash, Routing_table, Torrent_data, Metadata, Content, Id, K) ->
  Peers = maps:get(Hash, Torrent_data),
  {Node_Id, Pid} = lists:nth(rand:uniform(length(Peers)), Peers),
  Pid ! {want, [], {Id, self()}},
  receive
    {ack_want, error} ->
      error;
    {ack_want, Data} ->
      case hash(Data) of
        Hash ->
          listen(Routing_table, Torrent_data, Metadata, maps:put(Hash, Data, Content), Id, K);
        true ->
          wrong_data_error

      end
  end.

add_node_to_bucket(Node, Routing_table, Id, K) ->
  Index = find_closest_bucket(element(1, Node), Id),
  {Bucket, New_map} = maps:take(Index, Routing_table),
  BucketSize = length(Bucket),
  {Node_id, Pid} = Node,
  Distance = xor_distance(Node_id, Id),
  if
    BucketSize =< K ->
      New_bucket = lists:sort([{Distance, Node} | Bucket]),
      maps:put(Index, New_bucket, New_map);
    true ->
      New_bucket = [{Distance, Node}, lists:droplast(Bucket)],
      maps:put(Index, lists:sort(New_bucket), New_map)
  end.

%%Appears to be working. Should be properly tested.

find_closest_bucket(Node_Id, Id) ->

  if
    Node_Id == Id ->
      256;
    true ->
      Index = binary:longest_common_prefix([Id, Node_Id]),
      IdByte = binary:at(Id, Index),
      NodeByte = binary:at(Node_Id, Index),
      8 * Index + (8 - trunc(math:log2(IdByte bxor NodeByte) + 1))
  end.

%%Finds and returns the value.
find_value(Hash, Torrent_data) ->
  maps:get(Hash, Torrent_data, {not_available}).

%Hopefully the compiler is really clever with this abomination.
find_closest_nodes(K, Id, Target_node, Routing_table) ->

  Iterator = maps:iterator(Routing_table),
  Nodes = collect_nodes(Iterator, []),
  Sorted = sort_nodes(Target_node, Nodes).

find_closest_nodes(K, Id, Target_node, Routing_table, [Candidate|T]) ->
  Pid = self(),
  [{Candidate_distance, {Candidate_id, Candidate_pid}} | Candidate_T] = find_closest_nodes(K, Id, Target_node, Routing_table),
  Candidate_pid ! {find_node, Target_node, {Id, Pid}},
  receive
    {ack_find_node, Nodes, {Id, Pid}} ->
      case Nodes of
        [] ->
          [{Candidate_id, Candidate_pid} | Candidate_T];
        [{Candidate_id, Candidate_pid} | Other_T] ->
          New_state = add_nodes_to_bucket(Nodes, Routing_table, Id, K),
          Big_list = lists:merge3(Other_T, Candidate_T, [{Candidate_id, Candidate_pid}]),
          {New_state, sort_nodes(Target_node, Big_list)};
        [{Other_id, Other_pid} | Other_T] ->
          New_state = add_nodes_to_bucket(Nodes, Routing_table, Id, K),
          Other_distance = xor_distance(Other_id, Target_node),
          Candidate_distance = xor_distance(Candidate_id, Target_node),
          case Other_distance < Candidate_distance of
            true ->
              find_closest_nodes(K, Id, Target_node, Routing_table);
            false ->
              {New_state, sort_nodes(Target_node, [[{Other_id, Other_pid} | Other_T] | [{Candidate_id, Candidate_pid} | Candidate_T]])}
          end
      end
  end.



get_k_entries(K, Nodes) ->
  case Nodes of
    [] -> Nodes;
    Nodes ->
      [H | T] = Nodes,
      get_k_entries(K - 1, T, [H])
  end.

get_k_entries(K, Nodes, Entries) ->
  if
    K == 0 -> Entries;
    Nodes == [] -> Entries;
    true ->
      [H | T] = Nodes,
      get_k_entries(K - 1, T, [H | Entries])
  end.

collect_nodes(Iterator, Nodes) ->
  Next = maps:next(Iterator),
  case Next of
    none -> Nodes;
    {_, Node, Next_iterator} ->
      case Node of
        [] -> collect_nodes(Next_iterator, Nodes);
        Node ->
          collect_nodes(Next_iterator, lists:append(Node, Nodes))
      end
  end.

prepare_tuples_for_sorting(Target_node, Nodes, Prepared_nodes) ->

  case Nodes of
    [] -> Prepared_nodes;
    Nodes ->
      [Bucket | T] = Nodes,
      case Bucket of
        [] -> prepare_tuples_for_sorting(Target_node, T, Prepared_nodes);
        {_, {Node_Id, Pid}} ->
          prepare_tuples_for_sorting(Target_node, T, [{xor_distance(Target_node, Node_Id), {Node_Id, Pid}} | Prepared_nodes]);
        Bucket ->
          [{_, Node} | T_bucket] = Bucket,
          New_tuple = {xor_distance(element(1, Node), Target_node), Node},
          prepare_tuples_for_sorting(Target_node, [T_bucket | T], [New_tuple | Prepared_nodes])
      end

  end.

sort_nodes(Target_node, Nodes) ->
  Prepared = prepare_tuples_for_sorting(Target_node, Nodes, []),
  lists:sort(Prepared).

%%Calculates the XOR distance from Hash1 to Hash2.
%%Suspected to work properly, but not adequately tested.
xor_distance(K1, K2) ->
  K1size = size(K1) * 8,
  K2size = size(K2) * 8,
  <<Int1:K1size>> = K1,
  <<Int2:K2size>> = K2,
  Int1 bxor Int2.

initialize_buckets(Buckets, Iterations) ->
  if
    Iterations >= 0 -> initialize_buckets(maps:put(Iterations, [], Buckets), Iterations - 1);
    true -> Buckets
  end.