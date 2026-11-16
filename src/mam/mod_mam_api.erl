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
            Params = #{scope => {archive, MUCDomain, LRoom}, before_id => before_id(Before)},
            format_result(mongoose_hooks:mam_muc_delete_messages(HostType, Params));
        {error, not_found} ->
            ?MUC_SERVER_NOT_FOUND_RESULT
    end.

%% @doc Delete messages archived before `Before' from the archives of all rooms
%% of the MUC service `MUCDomain'.
-spec delete_old_room_messages(jid:lserver(), mod_mam:unix_timestamp()) -> delete_result().
delete_old_room_messages(MUCDomain, Before) ->
    case mongoose_domain_api:get_subdomain_host_type(MUCDomain) of
        {ok, HostType} ->
            Params = #{scope => {server, MUCDomain}, before_id => before_id(Before)},
            format_result(mongoose_hooks:mam_muc_delete_messages(HostType, Params));
        {error, not_found} ->
            ?MUC_SERVER_NOT_FOUND_RESULT
    end.

%% @doc Delete messages archived before `Before' from the one-to-one archive of a user.
-spec delete_user_messages(jid:jid(), mod_mam:unix_timestamp()) -> delete_result().
delete_user_messages(#jid{luser = LUser, lserver = LServer}, Before) ->
    case mongoose_domain_api:get_domain_host_type(LServer) of
        {ok, HostType} ->
            Params = #{scope => {archive, LServer, LUser}, before_id => before_id(Before)},
            format_result(mongoose_hooks:mam_delete_messages(HostType, Params));
        {error, not_found} ->
            ?DOMAIN_NOT_FOUND_RESULT
    end.

%% @doc Delete messages archived before `Before' from the one-to-one archives
%% of all users of `Domain'.
-spec delete_old_messages(jid:lserver(), mod_mam:unix_timestamp()) -> delete_result().
delete_old_messages(Domain, Before) ->
    case mongoose_domain_api:get_domain_host_type(Domain) of
        {ok, HostType} ->
            Params = #{scope => {server, Domain}, before_id => before_id(Before)},
            format_result(mongoose_hooks:mam_delete_messages(HostType, Params));
        {error, not_found} ->
            ?DOMAIN_NOT_FOUND_RESULT
    end.

%% Internal functions

%% Message IDs are timestamps in microseconds shifted left by 8 bits, with the node number
%% in the lowest byte. The lowest ID for the given microsecond has node number 0,
%% so `id < before_id(Before)' selects exactly the messages archived before `Before'.
-spec before_id(mod_mam:unix_timestamp()) -> non_neg_integer().
before_id(Before) ->
    mod_mam_utils:encode_compact_uuid(Before, 0).

-spec format_result({ok, non_neg_integer()} | {error, not_supported}) -> delete_result().
format_result({ok, Count}) ->
    {ok, Count};
format_result({error, not_supported}) ->
    ?NOT_SUPPORTED_RESULT.
