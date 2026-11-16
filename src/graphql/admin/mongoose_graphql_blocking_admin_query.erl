-module(mongoose_graphql_blocking_admin_query).

-behaviour(mongoose_graphql).

-export([execute/4]).

-ignore_xref([execute/4]).

-import(mongoose_graphql_helper, [make_error/2]).

execute(_Ctx, blocking, <<"getBlockingList">>, #{<<"user">> := User}) ->
    case mod_blocking_api:get_blocking_list(User) of
        {ok, JIDs} -> {ok, [{ok, JID} || JID <- JIDs]};
        Error -> make_error(Error, #{user => jid:to_binary(User)})
    end.
