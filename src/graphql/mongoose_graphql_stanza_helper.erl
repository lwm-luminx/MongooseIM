-module(mongoose_graphql_stanza_helper).

-import(mongoose_graphql_helper, [null_to_undefined/1, make_error/2]).

-export([get_last_messages/5, row_to_map/1, handle_event/1, handle_event/2]).

-include("mongoose.hrl").
-include("jlib.hrl").

-spec get_last_messages(Caller :: jid:jid(),
                        Limit :: null | non_neg_integer(),
                        With :: null | jid:jid(),
                        Before :: null | mod_mam:unix_timestamp(), boolean()) ->
          {ok, map()} | {unknown_user, iodata()}.
get_last_messages(Caller, Limit, With, Before, CheckUser) ->
    case mongoose_stanza_api:lookup_recent_messages(
           Caller, null_to_undefined(With), null_to_undefined(Before),
           null_to_undefined(Limit), CheckUser) of
        {ok, {Rows, Limit2}} ->
            Maps = lists:map(fun row_to_map/1, Rows),
            {ok, #{<<"stanzas">> => Maps, <<"limit">> => Limit2}};
        Error ->
            Error
    end.

-spec handle_event(term()) -> {ok, map() | null} | {ok, null, [{stream, close}]}.
handle_event(Event) ->
    handle_event(Event, #{presences => false}).

%% @doc Converts an event for a subscription stream. Messages are always passed,
%% and presences only when requested.
-spec handle_event(term(), #{presences := boolean()}) ->
          {ok, map() | null} | {ok, null, [{stream, close}]}.
handle_event({route, Acc}, #{presences := Presences}) ->
    {From, To, Packet} = mongoose_acc:packet(Acc),
    case Packet of
        #xmlel{name = <<"iq">>} ->
            reply_to_iq(From, To, Packet),
            {ok, null};
        #xmlel{name = Name} = Stanza when Name =:= <<"message">>;
                                          Name =:= <<"presence">> andalso Presences ->
            %% ejabberd_sm leaves the recipient's privacy checks to the session,
            %% so that blocked senders (XEP-0016, XEP-0191) are not delivered
            case is_allowed_by_privacy(Acc, From, To) of
                true -> route_result(From, Stanza);
                false -> {ok, null}
            end;
        _ ->
            {ok, null} % Skip other stanza types
    end;
handle_event(Event, _Opts) ->
    handle_other_event(Event).

%% A session can't answer requests, so they get an error instead of no response (RFC 6120, 8.2.3)
reply_to_iq(From, To, Packet) ->
    case exml_query:attr(Packet, <<"type">>) of
        Type when Type =:= <<"get">>; Type =:= <<"set">> ->
            Err = jlib:make_error_reply(Packet, mongoose_xmpp_errors:service_unavailable()),
            mongoose_router:route(mongoose_acc:new(To, From, Err, ?LOCATION)),
            ok;
        _ ->
            ok
    end.

is_allowed_by_privacy(Acc, From, To = #jid{lserver = LServer}) ->
    case mongoose_domain_api:get_domain_host_type(LServer) of
        {ok, HostType} ->
            PrivacyList = mongoose_hooks:privacy_get_user_list(HostType, To),
            {Decision, _} = mongoose_privacy:privacy_check_packet(Acc, To, PrivacyList,
                                                                  From, To, in),
            Decision =:= allow;
        {error, not_found} ->
            false
    end.

route_result(From, Stanza) ->
    StanzaID = exml_query:attr(Stanza, <<"id">>, <<>>),
    Timestamp = os:system_time(microsecond),
    stanza_result(From, Timestamp, StanzaID, Stanza).

handle_other_event({message, Dir, {UserPid, Jid}, Stanza}) ->
    Timestamp = os:system_time(microsecond),
    trace_result(Timestamp, UserPid, Jid, Dir, Stanza);
handle_other_event({mongoose_stanza_api, room_presence, Action, RoomJID}) ->
    mongoose_stanza_api:handle_room_presence(Action, RoomJID),
    {ok, null};
handle_other_event({'$gen_cast', {exit, Reason}}) ->
    %% ejabberd_sm ends a session with mongoose_c2s:exit/2, e.g. when the session is kicked,
    %% the user is removed or another session takes over the resource.
    %% Closing the stream runs 'terminate', which closes the session.
    ?LOG_INFO(#{what => graphql_sse_session_terminated, reason => Reason}),
    {ok, null, [{stream, close}]};
handle_other_event(Msg) ->
    ?UNEXPECTED_INFO(Msg),
    {ok, null}.

-spec row_to_map(mod_mam:message_row()) -> {ok, map()}.
row_to_map(#{id := Id, jid := From, packet := Stanza}) ->
    {Microseconds, _} = mod_mam_utils:decode_compact_uuid(Id),
    StanzaID = mod_mam_utils:mess_id_to_external_binary(Id),
    stanza_result(From, Microseconds, StanzaID, Stanza).

stanza_result(From, Timestamp, StanzaID, Stanza) ->
    Map = #{<<"sender">> => From, <<"timestamp">> => Timestamp,
            <<"stanza_id">> => StanzaID, <<"stanza">> => Stanza},
    {ok, Map}.

trace_result(Timestamp, UserPid, Jid, Dir, Stanza) ->
    Map = #{<<"pid">> => pid_to_binary(UserPid), <<"timestamp">> => Timestamp,
            <<"dir">> => atom_to_binary(Dir, utf8), <<"stanza">> => Stanza},
    Map1 = case Jid of
               undefined -> Map;
               J -> Map#{<<"jid">> => J}
           end,
    {ok, Map1}.

pid_to_binary(Pid) when is_pid(Pid) ->
    iolist_to_binary(io_lib:format("~p", [Pid])).

