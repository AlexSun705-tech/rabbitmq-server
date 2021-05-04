-module(rabbit_stream_core).

-include("rabbit_stream.hrl").
-export([
         init/1,
         incoming_data/2,
         frame/1,
         parse_command/1
         ]).

%% holds static or rarely changing fields
-record(cfg, {}).

-record(?MODULE, {cfg :: #cfg{},
                  frames = [] :: [iodata()],
                  %% partial data
                  data :: undefined |
                          %% this is only if the binary is smaller than 4 bytes
                          binary() |
                          {RemainingBytes :: non_neg_integer(), iodata()}
                 }).

-opaque state() :: #?MODULE{}.

-export_type([
              state/0
              ]).

-type correlation_id() :: non_neg_integer().
%% publishing sequence number
-type publishing_id() :: non_neg_integer().
-type publisher_id() :: 0..255.
-type subscription_id() :: 0..255.
-type writer_ref() :: binary().
-type stream_name() :: binary().
-type offset_spec() :: osiris:offset_spec().

-type response_code() ::
    ?RESPONSE_CODE_OK |
    ?RESPONSE_CODE_STREAM_DOES_NOT_EXIST |
    ?RESPONSE_CODE_SUBSCRIPTION_ID_ALREADY_EXISTS |
    ?RESPONSE_CODE_SUBSCRIPTION_ID_DOES_NOT_EXIST |
    ?RESPONSE_CODE_STREAM_ALREADY_EXISTS |
    ?RESPONSE_CODE_STREAM_NOT_AVAILABLE |
    ?RESPONSE_SASL_MECHANISM_NOT_SUPPORTED |
    ?RESPONSE_AUTHENTICATION_FAILURE |
    ?RESPONSE_SASL_ERROR |
    ?RESPONSE_SASL_CHALLENGE |
    ?RESPONSE_SASL_AUTHENTICATION_FAILURE_LOOPBACK |
    ?RESPONSE_VHOST_ACCESS_FAILURE |
    ?RESPONSE_CODE_UNKNOWN_FRAME |
    ?RESPONSE_CODE_FRAME_TOO_LARGE |
    ?RESPONSE_CODE_INTERNAL_ERROR |
    ?RESPONSE_CODE_ACCESS_REFUSED |
    ?RESPONSE_CODE_PRECONDITION_FAILED |
    ?RESPONSE_CODE_PUBLISHER_DOES_NOT_EXIST.

-type error_code() :: response_code().

-type sequence() :: non_neg_integer().
-type credit() :: non_neg_integer().
-type offset_ref() :: binary().
-type endpoint() :: {Host :: binary(), Port :: non_neg_integer()}.

-type command() ::
    {publish, publisher_id(), MessageCount :: non_neg_integer(), Payload :: binary()} |
    {publish_confirm, publisher_id(), [publishing_id()]} |
    {publish_error, publisher_id(), error_code(), [publishing_id()]} |
    %% not used by stream plugin - receiving side only
    {deliver, subscription_id(), Chunk :: binary()} |
    {credit, subscription_id(), Credit :: non_neg_integer()} |
    {metadata_update, stream_name(), response_code()} |
    heartbeat |
    {tune, FrameMax :: non_neg_integer(), HeartBeat :: non_neg_integer()} |
    {request, correlation_id(),
     {declare_publisher, publisher_id(), writer_ref(), stream_name()} |
     {query_publisher_sequence, writer_ref(), stream_name()} |
     {delete_publisher, publisher_id()} |
     {subscribe, subscription_id(), stream_name(), offset_spec(), credit()} |
     %% correlation_id is not used
     {commit_offset, offset_ref(), stream_name(), osiris:offset()} |
     {query_offset, offset_ref(), stream_name()} |
     {unsubscribe, subscription_id()} |
     {create_stream, stream_name(), Args :: #{binary() => binary()}} |
     {delete_stream, stream_name()} |
     {metadata, [stream_name()]} |
     {peer_properties, #{binary() => binary()}} |
     sasl_handshake |
     %% TODO: look into
     {sasl_authenticate, Mechanism :: binary(), SaslFragment :: binary()} |
     {open, VirtualHost :: binary()} |
     {close, Code :: non_neg_integer(), Reason :: binary()} |
     {route, RoutingKey :: binary(), SuperStream :: binary()} |
     {partitions, SuperStream :: binary()}} |
    {response, correlation_id(),
     {declare_publisher |
      delete_publisher |
      subscribe |
      unsubscribe |
      create_stream |
      delete_stream |
      open |
      close,
      response_code()} |
     {query_publisher_sequence, response_code(), sequence()} |
     %% commit offset has no response
     % {commit_offset, offset_ref(), stream_name(), osiris:offset()} |
     {query_offset, response_code(), osiris:offset()} |
     {metadata,
      Nodes :: [endpoint()],
      Metadata :: #{stream_name() =>
                    stream_not_found |
                    stream_not_available |
                    {Leader :: endpoint(), Replicas :: [endpoint()]}}} |
     {peer_properties, response_code(), #{binary() => binary()}} |
     {sasl_handshake, response_code(), Mechanisms :: [binary()]} |
     %% either response code or sasl fragment
     {sasl_authenticate, response_code(), Challenge :: binary()} |
     {tune, FrameMax :: non_neg_integer(), HeartBeat :: non_neg_integer()} |
     %% TODO should route return a list of routed streams?
     {route, response_code(), stream_name()} |
     {partitions, response_code(), [stream_name()]}
    } |
    {unknown, binary()}.

-spec init(term()) -> state().
init(_) ->
    #?MODULE{cfg = #cfg{}}.

%% returns frames
-spec incoming_data(binary(), state()) ->
    {state(), [command()]}.
%% TODO: check max frame size
incoming_data(<<>>, #?MODULE{frames = Frames} = State) ->
    {State#?MODULE{frames = []}, parse_frames(Frames)};
incoming_data(<<Size:32/unsigned, Frame:Size/binary, Rem/binary>>,
              #?MODULE{frames = Frames,
                       data = undefined} = State) ->
    incoming_data(Rem, State#?MODULE{frames = [Frame | Frames],
                                     data = undefined});
incoming_data(<<Size:32/unsigned, Rem/binary>>,
              #?MODULE{frames = Frames,
                       data = undefined} = State) ->
    %% not enough data to complete frame, stash and await more data
    {State#?MODULE{frames = [],
                   data = {Size, Rem}},
     parse_frames(Frames)};
incoming_data(Data,
              #?MODULE{frames = Frames,
                       data = {Size, Partial}} = State) ->
    case Data of
        <<Data:Size/binary, Rem/binary>> ->
            incoming_data(Rem, State#?MODULE{frames = [append_data(Partial, [Data])
                                                       | Frames],
                                             data = undefined});
        Rem ->
            {State#?MODULE{frames = [],
                           data = {Size - byte_size(Rem),
                                   append_data(Partial, Rem)}},
             parse_frames(Frames)}
    end;
incoming_data(Data, #?MODULE{data = Partial} = State)
  when is_binary(Partial) ->
    incoming_data(<<Partial/binary, Data/binary>>,
                  State#?MODULE{data = undefined}).

parse_frames(Frames) ->
    lists:foldl(
      fun (Frame, Acc) ->
              [parse_command(Frame) | Acc]
      end, [], Frames).

-spec frame(command()) -> iodata().
frame({publish_confirm, PublisherId, PublishingIds}) ->
    PubIds = lists:foldl(
               fun(PublishingId, Acc) ->
                       <<Acc/binary, PublishingId:64>>
               end, <<>>, PublishingIds),
    PublishingIdCount = length(PublishingIds),
    Body = [<<?REQUEST:1,
              ?COMMAND_PUBLISH_CONFIRM:15,
              ?VERSION_1:16,
              PublisherId:8,
              PublishingIdCount:32>>,
            PubIds],
    wrap_in_frame(Body);
frame(_Command) ->
    [].

append_data(Prev, Data) when is_binary(Prev) ->
    [Prev, Data];
append_data(Prev, Data) when is_list(Prev) ->
    Prev ++ [Data].

wrap_in_frame(IOData) ->
    Size = iolist_size(IOData),
    [<<Size:32>> | IOData].

parse_command(<<?REQUEST:1, _:15, _/binary>> = Bin) ->
    parse_request(Bin);
parse_command(<<?RESPONSE:1, _:15, _/binary>> = Bin) ->
    parse_response(Bin);
parse_command(Data) when is_list(Data) ->
    %% TODO: most commands are rare or small and likely to be a single
    %% binary, however publish and delivery should be parsed from the
    %% iodata rather than turned into a binary
    parse_command(iolist_to_binary(Data)).

-define(STRING(Size, Str), Size:16, Str:Size/binary).

-spec parse_request(binary()) -> command().
parse_request(<<?REQUEST:1, ?COMMAND_PUBLISH:15, ?VERSION_1:16,
                PublisherId:8/unsigned, MessageCount:32, Messages/binary>>) ->
    {publish, PublisherId, MessageCount, Messages};
parse_request(<<?REQUEST:1, ?COMMAND_PUBLISH_CONFIRM:15, ?VERSION_1:16,
                PublisherId:8, _Count:32, PublishingIds/binary>>) ->
    {publish_confirm, PublisherId, list_of_longs(PublishingIds)};
parse_request(<<?REQUEST:1, ?COMMAND_DELIVER:15, ?VERSION_1:16,
                SubscriptionId:8, Chunk/binary>>) ->
    {deliver, SubscriptionId, Chunk};
parse_request(<<?REQUEST:1, ?COMMAND_CREDIT:15, ?VERSION_1:16,
                SubscriptionId:8, Credit:16/signed>>) ->
    {credit, SubscriptionId, Credit};
parse_request(<<?REQUEST:1, ?COMMAND_PUBLISH_ERROR:15, ?VERSION_1:16,
                PublisherId:8, _Count:32, DetailsBin/binary>>) ->
    %% TODO: change protocol to match
    [{_, ErrCode} | _] = Details = list_of_longcodes(DetailsBin),
    {PublishingIds, _} = lists:unzip(Details),
    {publish_error, PublisherId, ErrCode, PublishingIds};
parse_request(<<?REQUEST:1, ?COMMAND_METADATA_UPDATE:15, ?VERSION_1:16,
                ResponseCode:16, StreamSize:16, Stream:StreamSize/binary>>) ->
    {metadata_update, Stream, ResponseCode};
parse_request(<<?REQUEST:1, ?COMMAND_HEARTBEAT:15, ?VERSION_1:16>>) ->
    heartbeat;
parse_request(<<?REQUEST:1, ?COMMAND_DECLARE_PUBLISHER:15, ?VERSION_1:16,
                CorrelationId:32, PublisherId:8,
                ?STRING(WriterRefSize, WriterRef),
                ?STRING(StreamSize, Stream)>>) ->
     request(CorrelationId,
             {declare_publisher, PublisherId, WriterRef, Stream});
parse_request(<<?REQUEST:1, ?COMMAND_QUERY_PUBLISHER_SEQUENCE:15, ?VERSION_1:16,
                CorrelationId:32,
                ?STRING(WSize, WriterReference),
                ?STRING(SSize, Stream)>>) ->
    request(CorrelationId,
            {query_publisher_sequence, WriterReference, Stream});
parse_request(<<?REQUEST:1, ?COMMAND_DELETE_PUBLISHER:15, ?VERSION_1:16,
                CorrelationId:32, PublisherId:8>>) ->
    request(CorrelationId, {delete_publisher, PublisherId});
parse_request(<<?REQUEST:1, ?COMMAND_SUBSCRIBE:15, ?VERSION_1:16,
                CorrelationId:32, SubscriptionId:8,
                ?STRING(StreamSize, Stream),
                         OffsetType:16/signed,
                         OffsetAndCredit/binary>>) ->
    {OffsetSpec, Credit} = case OffsetType of
                               ?OFFSET_TYPE_FIRST ->
                                   <<Crdt:16>> = OffsetAndCredit,
                                   {first, Crdt};
                               ?OFFSET_TYPE_LAST ->
                                   <<Crdt:16>> = OffsetAndCredit,
                                   {last, Crdt};
                               ?OFFSET_TYPE_NEXT ->
                                   <<Crdt:16>> = OffsetAndCredit,
                                   {next, Crdt};
                               ?OFFSET_TYPE_OFFSET ->
                                   <<Offset:64/unsigned, Crdt:16>> =
                                   OffsetAndCredit,
                                   {Offset, Crdt};
                               ?OFFSET_TYPE_TIMESTAMP ->
                                   <<Timestamp:64/signed, Crdt:16>> =
                                   OffsetAndCredit,
                                   {{timestamp, Timestamp}, Crdt}
                           end,
    request(CorrelationId,
            {subscribe, SubscriptionId, Stream, OffsetSpec, Credit});
parse_request(<<?REQUEST:1, ?COMMAND_COMMIT_OFFSET:15, ?VERSION_1:16,
                _CorrelationId:32,
                ?STRING(RefSize, OffsetRef),
                ?STRING(SSize, Stream),
                Offset:64>>) ->
    %% NB: this request has no response so ignoring correlation id here
    {commit_offset, OffsetRef, Stream, Offset};
parse_request(<<?REQUEST:1, ?COMMAND_QUERY_OFFSET:15, ?VERSION_1:16,
                CorrelationId:32,
                ?STRING(RefSize, OffsetRef),
                ?STRING(SSize, Stream)>>) ->
    request(CorrelationId, {query_offset, OffsetRef, Stream});
parse_request(<<?REQUEST:1, ?COMMAND_UNSUBSCRIBE:15, ?VERSION_1:16,
                CorrelationId:32, SubscriptionId:8>>) ->
    request(CorrelationId, {unsubscribe, SubscriptionId});
parse_request(<<?REQUEST:1, ?COMMAND_CREATE_STREAM:15, ?VERSION_1:16,
                CorrelationId:32,
                ?STRING(StreamSize, Stream),
                _ArgumentsCount:32,
                ArgumentsBinary/binary>>) ->
    Args = parse_map(ArgumentsBinary, #{}),
    request(CorrelationId, {create_stream, Stream, Args});
parse_request(<<?REQUEST:1, ?COMMAND_DELETE_STREAM:15, ?VERSION_1:16,
                CorrelationId:32,
                ?STRING(StreamSize, Stream)>>) ->
    request(CorrelationId, {delete_stream, Stream});
parse_request(<<?REQUEST:1, ?COMMAND_METADATA:15, ?VERSION_1:16,
                CorrelationId:32, _StreamCount:32,
                BinaryStreams/binary>>) ->
    Streams = list_of_strings(BinaryStreams),
    request(CorrelationId, {metadata, Streams});
parse_request(<<?REQUEST:1, ?COMMAND_PEER_PROPERTIES:15, ?VERSION_1:16,
                CorrelationId:32, _PropertiesCount:32,
                PropertiesBinary/binary>>) ->
    Props = parse_map(PropertiesBinary, #{}),
    request(CorrelationId, {peer_properties, Props});
parse_request(<<?REQUEST:1, ?COMMAND_SASL_HANDSHAKE:15, ?VERSION_1:16,
                CorrelationId:32>>) ->
    request(CorrelationId, sasl_handshake);
parse_request(<<?REQUEST:1, ?COMMAND_SASL_AUTHENTICATE:15, ?VERSION_1:16,
                CorrelationId:32,
                ?STRING(MechanismSize, Mechanism),
                SaslFragment/binary>>) ->
    SaslBin =
        case SaslFragment of
            <<(-1):32/signed>> ->
                <<>>;
            <<SaslBinaryLength:32, SaslBinary:SaslBinaryLength/binary>> ->
                SaslBinary
        end,
    request(CorrelationId,
             {sasl_authenticate, Mechanism, SaslBin});
parse_request(<<?REQUEST:1, ?COMMAND_TUNE:15, ?VERSION_1:16,
                FrameMax:32, Heartbeat:32>>) ->
    %% NB: no correlatio id but uses the response bit
     {tune, FrameMax, Heartbeat};
parse_request(<<?REQUEST:1, ?COMMAND_OPEN:15, ?VERSION_1:16,
                CorrelationId:32,
                ?STRING(VhostSize, VirtualHost)>>) ->
    request(CorrelationId,
            {open, VirtualHost});
parse_request(<<?REQUEST:1, ?COMMAND_CLOSE:15, ?VERSION_1:16,
                CorrelationId:32,
                CloseCode:16,
                ?STRING(ReasonSize, Reason)>>) ->
    request(CorrelationId,
            {close, CloseCode, Reason});
parse_request(<<?REQUEST:1, ?COMMAND_ROUTE:15, ?VERSION_1:16,
                CorrelationId:32,
                ?STRING(RKeySize, RoutingKey),
                ?STRING(StreamSize, SuperStream)>>) ->
    request(CorrelationId,
            {route, RoutingKey, SuperStream});
parse_request(<<?REQUEST:1, ?COMMAND_PARTITIONS:15, ?VERSION_1:16,
                CorrelationId:32,
                ?STRING(StreamSize, SuperStream)>>) ->
    request(CorrelationId,
            {partitions, SuperStream});
parse_request(Bin) ->
    {unknown, Bin}.

parse_response(<<?RESPONSE:1, CommandId:15, ?VERSION_1:16,
                 CorrelationId:32, ResponseCode:16>>) ->
    {response, CorrelationId, {parse_command_id(CommandId), ResponseCode}};
parse_response(<<?RESPONSE:1, ?COMMAND_TUNE:15, ?VERSION_1:16,
                 FrameMax:32, Heartbeat:32>>) ->
    {tune, FrameMax, Heartbeat};
parse_response(<<?RESPONSE:1, CommandId:15, ?VERSION_1:16,
                 CorrelationId:32, Data/binary>>) ->
    {response, CorrelationId, parse_response_body(CommandId, Data)};
parse_response(Bin) ->
    {unknown, Bin}.

parse_response_body(?COMMAND_QUERY_PUBLISHER_SEQUENCE,
                   <<ResponseCode:16, Sequence:64>>) ->
    {query_publisher_sequence, ResponseCode, Sequence};
parse_response_body(?COMMAND_QUERY_OFFSET,
                   <<ResponseCode:16, Offset:64>>) ->
     {query_offset, ResponseCode, Offset};
parse_response_body(?COMMAND_METADATA, <<NumNodes:32, Data/binary>>) ->
    {NodesLookup, MetadataBin} = parse_nodes(Data, NumNodes, #{}),
    Nodes = maps:values(NodesLookup),
    Metadata = parse_meta(MetadataBin, NodesLookup, #{}),
    {metadata, Nodes, Metadata};
parse_response_body(?COMMAND_PEER_PROPERTIES,
                   <<ResponseCode:16, _Count:32, PropertiesBin/binary>>) ->
    Props = parse_map(PropertiesBin, #{}),
     {peer_properties, ResponseCode, Props};
parse_response_body(?COMMAND_SASL_HANDSHAKE,
                   <<ResponseCode:16, _Count:32, MechanismsBin/binary>>) ->
    Props = list_of_strings(MechanismsBin),
     {peer_properties, ResponseCode, Props};
parse_response_body(?COMMAND_SASL_AUTHENTICATE,
                   <<ResponseCode:16, ChallengeBin/binary>>) ->
    Challenge = case ChallengeBin of
                    <<?STRING(CSize, Chall)>> ->
                        Chall;
                    <<>> ->
                        <<>>
                end,
     {sasl_authenticate, ResponseCode, Challenge};
parse_response_body(?COMMAND_ROUTE,
                   <<ResponseCode:16,
                     ?STRING(StreamSize, Stream)>>) ->
     {route, ResponseCode, Stream};
parse_response_body(?COMMAND_PARTITIONS,
                   <<ResponseCode:16,
                     _Count:32,
                     PartitionsBin/binary>>) ->
    Partitions = list_of_strings(PartitionsBin),
     {partitions, ResponseCode, Partitions}.

request(Corr, Cmd) ->
    {request, Corr, Cmd}.

parse_meta(<<>>, _Nodes, Acc) ->
    Acc;
parse_meta(<<?STRING(StreamSize, Stream),
              Code:16,
              LeaderIndex:16,
              ReplicaCount:32,
              ReplicaIndexBin:(ReplicaCount * 16)/binary,
              Rem/binary>>, Nodes,
            Acc) ->
    StreamDetail = case Code of
                       ?RESPONSE_CODE_OK ->
                           Leader = maps:get(LeaderIndex, Nodes),
                           Replicas = [maps:get(I, Nodes) ||
                                       I <- list_of_shorts(ReplicaIndexBin)],
                           {Leader, Replicas};
                       ?RESPONSE_CODE_STREAM_DOES_NOT_EXIST ->
                           stream_not_found;
                       ?RESPONSE_CODE_STREAM_NOT_AVAILABLE ->
                           stream_not_available
                   end,
    parse_meta(Rem, Nodes, Acc#{Stream => StreamDetail}).

parse_nodes(Rem, 0, Acc) ->
    {Acc, Rem};
parse_nodes(<<Index:16,
              ?STRING(HostSize, Host),
              Port:32, Rem/binary>>, C, Acc) ->
    parse_nodes(Rem, C - 1, Acc#{Index => {Host, Port}}).

parse_map(<<>>, Acc) ->
    Acc;
parse_map(<<?STRING(KeySize, Key),
            ?STRING(ValSize, Value),
            Rem/binary>>, Acc) ->
    parse_map(Rem, Acc#{Key => Value}).

list_of_strings(<<>>) ->
    [];
list_of_strings(<<?STRING(Size, String), Rem/binary>>) ->
    [String | list_of_strings(Rem)].

list_of_longs(<<>>) ->
    [];
list_of_longs(<<I:64, Rem/binary>>) ->
    [I | list_of_longs(Rem)].

list_of_shorts(<<>>) ->
    [];
list_of_shorts(<<I:16, Rem/binary>>) ->
    [I | list_of_shorts(Rem)].

list_of_longcodes(<<>>) ->
    [];
list_of_longcodes(<<I:64, C:16, Rem/binary>>) ->
    [{I, C} | list_of_longcodes(Rem)].


parse_command_id(?COMMAND_DECLARE_PUBLISHER) -> declare_publisher;
parse_command_id(?COMMAND_DELETE_PUBLISHER) -> delete_publisher;
parse_command_id(?COMMAND_SUBSCRIBE) -> subscribe;
parse_command_id(?COMMAND_UNSUBSCRIBE) -> unsubscribe;
parse_command_id(?COMMAND_CREATE_STREAM) -> create_stream;
parse_command_id(?COMMAND_DELETE_STREAM) -> delete_stream;
parse_command_id(?COMMAND_OPEN) -> open;
parse_command_id(?COMMAND_CLOSE) -> close.

% command_id(declare_publisher) -> ?COMMAND_DECLARE_PUBLISHER;
% command_id(delete_publisher) -> ?COMMAND_DELETE_PUBLISHER;
% command_id(subscribe) -> ?COMMAND_SUBSCRIBE;
% command_id(unsubscribe) -> ?COMMAND_UNSUBSCRIBE;
% command_id(create_stream) -> ?COMMAND_CREATE_STREAM;
% command_id(delete_stream) -> ?COMMAND_DELETE_STREAM;
% command_id(open) -> ?COMMAND_OPEN;
% command_id(close) -> ?COMMAND_CLOSE.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
