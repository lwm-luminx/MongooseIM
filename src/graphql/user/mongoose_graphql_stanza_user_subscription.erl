-module(mongoose_graphql_stanza_user_subscription).
-behaviour(mongoose_graphql).

-import(mongoose_graphql_helper, [format_result/2]).

-export([execute/4]).

-ignore_xref([execute/4]).

-include("../mongoose_graphql_types.hrl").

execute(Ctx, _Obj, <<"subscribeForMessages">>, Args) ->
    subscribe_for_messages(Ctx, Args).

subscribe_for_messages(#{event := terminate, stream := Session}, _) ->
    mongoose_stanza_api:close_session(Session),
    {ok, null, [{stream, closed}]};
subscribe_for_messages(#{event := Event}, Args) ->
    Presences = maps:get(<<"presences">>, Args, false) =:= true,
    mongoose_graphql_stanza_helper:handle_event(Event, #{presences => Presences});
subscribe_for_messages(#{user := Jid}, Args) ->
    Resource = null_to_undefined(maps:get(<<"resource">>, Args, null)),
    case mongoose_stanza_api:open_session(Jid, false, Resource) of
        {ok, Stream} ->
            {ok, null, [{stream, Stream}]};
        Error ->
            format_result(Error, #{resource => Resource})
    end.

null_to_undefined(null) -> undefined;
null_to_undefined(Value) -> Value.
