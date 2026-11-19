%% @doc API for managing the users' blocking lists (XEP-0191) without a session.
-module(mod_blocking_api).

-export([get_blocking_list/1, block/2, unblock/2]).

-include("jlib.hrl").
-include("mod_privacy.hrl").

-type error() :: {domain_not_found | user_not_found | bad_request | internal, iodata()}.

%% @doc Returns the JIDs blocked by the user.
-spec get_blocking_list(jid:jid()) -> {ok, [jid:jid()]} | error().
get_blocking_list(User = #jid{luser = LUser, lserver = LServer}) ->
    maybe
        {ok, HostType} ?= get_host_type(User),
        {ok, List} ?= mod_blocking:get_blocking_list(HostType, LUser, LServer),
        %% A "blocking" list written over XEP-0016 may hold group or subscription
        %% items, which are not JIDs
        {ok, [jid:make_noprep(Value) || #listitem{type = jid, value = Value} <- List]}
    else
        {error, _} -> internal_error();
        Error -> Error
    end.

%% @doc Blocks the given JIDs for the user. Returns the blocked JIDs.
-spec block(jid:jid(), [jid:jid(), ...]) -> {ok, [jid:jid()]} | error().
block(User, JIDs) ->
    case lists:any(fun(JID) -> jid:are_bare_equal(User, JID) end, JIDs) of
        true ->
            %% Blocking one's own JID would also drop the blocking and roster pushes
            {bad_request, <<"A user cannot block their own JID">>};
        false ->
            set_blocking_list(User, block, JIDs)
    end.

%% @doc Unblocks the given JIDs for the user. Returns the JIDs that were blocked before.
-spec unblock(jid:jid(), [jid:jid(), ...]) -> {ok, [jid:jid()]} | error().
unblock(User, JIDs) ->
    set_blocking_list(User, unblock, JIDs).

%% Helpers

set_blocking_list(User = #jid{luser = LUser, lserver = LServer}, Type, JIDs) ->
    BinJIDs = lists:usort([jid:to_binary(jid:to_lower(JID)) || JID <- JIDs]),
    maybe
        {ok, HostType} ?= get_host_type(User),
        {ok, Changed} ?= mod_blocking:set_blocking_list(HostType, LUser, LServer, Type, BinJIDs),
        {ok, [JID || JID <- lists:map(fun jid:from_binary/1, Changed), JID =/= error]}
    else
        {error, _} -> internal_error();
        Error -> Error
    end.

get_host_type(User = #jid{lserver = LServer}) ->
    case mongoose_domain_api:get_domain_host_type(LServer) of
        {ok, HostType} ->
            case ejabberd_auth:does_user_exist(HostType, User, stored) of
                true -> {ok, HostType};
                false -> {user_not_found, <<"User does not exist">>}
            end;
        {error, not_found} ->
            {domain_not_found, <<"User's domain does not exist">>}
    end.

internal_error() ->
    {internal, <<"Cannot access the blocking list">>}.
