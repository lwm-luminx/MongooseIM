%% @doc API for deleting archived messages (XEP-0313) older than a given date.
%%
%% The deletion itself is done by the archive backend, which handles the
%% `mam_delete_messages' (one-to-one archives) and `mam_muc_delete_messages'
%% (room archives) hooks. A backend that does not handle them leaves the
%% initial `{error, not_supported}' result.
-module(mod_mam_api).

-export([delete_room_messages/2,
         delete_old_room_messages/2,
         delete_user_messages/2,
         delete_old_messages/2]).

-include("jlib.hrl").

-type delete_result() :: {ok, non_neg_integer()}
                       | {muc_server_not_found | domain_not_found | not_supported, iolist()}.
-export_type([delete_result/0]).

-define(MUC_SERVER_NOT_FOUND_RESULT, {muc_server_not_found, "MUC server not found"}).
-define(DOMAIN_NOT_FOUND_RESULT, {domain_not_found, "Domain not found"}).
-define(NOT_SUPPORTED_RESULT,
        {not_supported, "Deleting archived messages is not supported by the configured backend"}).

%% @doc Delete messages archived before `Before' from the archive of one room.
-spec delete_room_messages(jid:jid(), mod_mam:unix_timestamp()) -> delete_result().
delete_room_messages(#jid{luser = LRoom, lserver = MUCDomain}, Before) ->
    case mongoose_domain_api:get_subdomain_host_type(MUCDomain) of
        {ok, HostType} ->
            delete_muc(HostType, {archive, MUCDomain, LRoom}, Before);
        {error, not_found} ->
            ?MUC_SERVER_NOT_FOUND_RESULT
    end.

%% @doc Delete messages archived before `Before' from the archives of all rooms
%% of the MUC service `MUCDomain'.
-spec delete_old_room_messages(jid:lserver(), mod_mam:unix_timestamp()) -> delete_result().
delete_old_room_messages(MUCDomain, Before) ->
    case mongoose_domain_api:get_subdomain_host_type(MUCDomain) of
        {ok, HostType} ->
            delete_muc(HostType, {server, MUCDomain}, Before);
        {error, not_found} ->
            ?MUC_SERVER_NOT_FOUND_RESULT
    end.

%% @doc Delete messages archived before `Before' from the one-to-one archive of a user.
-spec delete_user_messages(jid:jid(), mod_mam:unix_timestamp()) -> delete_result().
delete_user_messages(#jid{luser = LUser, lserver = LServer}, Before) ->
    case mongoose_domain_api:get_domain_host_type(LServer) of
        {ok, HostType} ->
            delete_pm(HostType, {archive, LServer, LUser}, Before);
        {error, not_found} ->
            ?DOMAIN_NOT_FOUND_RESULT
    end.

%% @doc Delete messages archived before `Before' from the one-to-one archives
%% of all users of `Domain'.
-spec delete_old_messages(jid:lserver(), mod_mam:unix_timestamp()) -> delete_result().
delete_old_messages(Domain, Before) ->
    case mongoose_domain_api:get_domain_host_type(Domain) of
        {ok, HostType} ->
            delete_pm(HostType, {server, Domain}, Before);
        {error, not_found} ->
            ?DOMAIN_NOT_FOUND_RESULT
    end.

%% Internal functions

%% The async writer (enabled by default) buffers messages for up to `flush_interval'
%% before inserting them. Flush it first, so that messages archived before `Before'
%% but still buffered are deleted too, instead of being inserted after the deletion.
-spec delete_pm(mongooseim:host_type(), mod_mam:delete_messages_scope(),
                mod_mam:unix_timestamp()) -> delete_result().
delete_pm(HostType, Scope, Before) ->
    case before_id(Before) of
        none ->
            {ok, 0};
        BeforeID ->
            mongoose_hooks:mam_archive_sync(HostType),
            Params = #{scope => Scope, before_id => BeforeID},
            format_result(mongoose_hooks:mam_delete_messages(HostType, Params))
    end.

-spec delete_muc(mongooseim:host_type(), mod_mam:delete_messages_scope(),
                 mod_mam:unix_timestamp()) -> delete_result().
delete_muc(HostType, Scope, Before) ->
    case before_id(Before) of
        none ->
            {ok, 0};
        BeforeID ->
            mongoose_hooks:mam_muc_archive_sync(HostType),
            Params = #{scope => Scope, before_id => BeforeID},
            format_result(mongoose_hooks:mam_muc_delete_messages(HostType, Params))
    end.

%% Message IDs are timestamps in microseconds shifted left by 8 bits, with the node number
%% in the lowest byte. The lowest ID for the given microsecond has node number 0,
%% so `id < before_id(Before)' selects exactly the messages archived before `Before'.
%% No message is archived before 1970, so an earlier date deletes nothing (and would give
%% a negative ID). IDs are stored as signed 64-bit integers, so a date after the largest
%% possible ID (in the year 4253) is clamped to it: `id < MaxID' still selects every message
%% but the one with exactly that ID, which can't exist before then.
-define(MAX_ID, 16#7FFFFFFFFFFFFFFF).
-spec before_id(mod_mam:unix_timestamp()) -> pos_integer() | none.
before_id(Before) when Before =< 0 ->
    none;
before_id(Before) ->
    min(mod_mam_utils:encode_compact_uuid(Before, 0), ?MAX_ID).

-spec format_result({ok, non_neg_integer()} | {error, not_supported}) -> delete_result().
format_result({ok, Count}) ->
    {ok, Count};
format_result({error, not_supported}) ->
    ?NOT_SUPPORTED_RESULT.
