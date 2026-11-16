-module(mongoose_graphql_blocking_admin_mutation).

-behaviour(mongoose_graphql).

-export([execute/4]).

-ignore_xref([execute/4]).

-import(mongoose_graphql_helper, [make_error/2, make_error/3]).

execute(_Ctx, blocking, <<"block">>, Args) ->
    set_blocking(fun mod_blocking_api:block/2, Args);
execute(_Ctx, blocking, <<"unblock">>, Args) ->
    set_blocking(fun mod_blocking_api:unblock/2, Args).

set_blocking(_Fun, #{<<"user">> := User, <<"jids">> := []}) ->
    make_error(bad_request, <<"At least one JID is required">>, #{user => jid:to_binary(User)});
set_blocking(Fun, #{<<"user">> := User, <<"jids">> := JIDs}) ->
    case Fun(User, JIDs) of
        {ok, Changed} -> {ok, [{ok, JID} || JID <- Changed]};
        Error -> make_error(Error, #{user => jid:to_binary(User)})
    end.
