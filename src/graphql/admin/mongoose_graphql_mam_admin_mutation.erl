-module(mongoose_graphql_mam_admin_mutation).
-behaviour(mongoose_graphql).

-export([execute/4]).

-ignore_xref([execute/4]).

-include("../mongoose_graphql_types.hrl").

-import(mongoose_graphql_helper, [make_error/2]).

execute(_Ctx, mam, <<"deleteRoomMessages">>, #{<<"room">> := RoomJID, <<"before">> := Before}) ->
    format_result(mod_mam_api:delete_room_messages(RoomJID, Before),
                  #{room => jid:to_binary(RoomJID)});
execute(_Ctx, mam, <<"deleteOldRoomMessages">>,
        #{<<"mucDomain">> := MUCDomain, <<"before">> := Before}) ->
    format_result(mod_mam_api:delete_old_room_messages(MUCDomain, Before),
                  #{mucDomain => MUCDomain});
execute(_Ctx, mam, <<"deleteUserMessages">>, #{<<"user">> := UserJID, <<"before">> := Before}) ->
    format_result(mod_mam_api:delete_user_messages(UserJID, Before),
                  #{user => jid:to_binary(UserJID)});
execute(_Ctx, mam, <<"deleteOldMessages">>, #{<<"domain">> := Domain, <<"before">> := Before}) ->
    format_result(mod_mam_api:delete_old_messages(Domain, Before),
                  #{domain => Domain}).

-spec format_result(mod_mam_api:delete_result(), map()) ->
          {ok, non_neg_integer()} | {error, resolver_error()}.
format_result({ok, Count}, _Context) ->
    {ok, Count};
format_result(Error, Context) ->
    make_error(Error, Context).
