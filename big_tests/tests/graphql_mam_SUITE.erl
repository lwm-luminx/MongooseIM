-module(graphql_mam_SUITE).

-compile([export_all, nowarn_export_all]).

-import(distributed_helper, [mim/0, require_rpc_nodes/1, subhost_pattern/1]).
-import(domain_helper, [host_type/0, domain/0, secondary_domain/0]).
-import(graphql_helper, [execute_command/4, get_ok_value/2, get_err_code/1,
                         get_unauthorized/1, get_not_loaded/1]).
-import(mam_helper, [rpc_apply/3]).

-include_lib("eunit/include/eunit.hrl").

-define(ROOM_DELETE_PATH, [data, mam, deleteRoomMessages]).
-define(OLD_ROOM_DELETE_PATH, [data, mam, deleteOldRoomMessages]).
-define(USER_DELETE_PATH, [data, mam, deleteUserMessages]).
-define(USER_ROOM_DELETE_PATH, [data, mam, deleteUserRoomMessages]).
-define(OLD_DELETE_PATH, [data, mam, deleteOldMessages]).

%% Messages are archived at these dates, and deleted before the cut-off date
-define(DATES, [{{2020, 1, 1}, {10, 0, 0}}, {{2020, 1, 3}, {10, 0, 0}}, {{2020, 1, 5}, {10, 0, 0}}]).
-define(BEFORE, <<"2020-01-04T00:00:00Z">>).

suite() ->
    require_rpc_nodes([mim]) ++ escalus:suite().

all() ->
    [{group, admin_http},
     {group, admin_cli},
     {group, domain_admin},
     {group, removed_users}].

groups() ->
    [{admin_http, [], admin_groups()},
     {admin_cli, [], admin_groups()},
     {domain_admin, [], domain_admin_groups()},
     {admin_mam, [], admin_mam_tests()},
     {admin_mam_not_configured, [], mam_not_configured_tests()},
     {domain_admin_mam, [], domain_admin_mam_tests()},
     {domain_admin_mam_not_configured, [], mam_not_configured_tests()},
     {removed_users, [], removed_users_tests()}].

admin_groups() ->
    [{group, admin_mam},
     {group, admin_mam_not_configured}].

domain_admin_groups() ->
    [{group, domain_admin_mam},
     {group, domain_admin_mam_not_configured}].

admin_mam_tests() ->
    [delete_room_messages,
     delete_room_messages_from_empty_archive,
     delete_old_room_messages,
     delete_user_room_messages,
     delete_all_user_room_messages,
     delete_user_messages,
     delete_old_messages,
     delete_room_messages_unknown_muc_server,
     delete_old_room_messages_unknown_muc_server,
     delete_user_messages_unknown_domain,
     delete_old_messages_unknown_domain].

domain_admin_mam_tests() ->
    [delete_room_messages,
     delete_room_messages_from_empty_archive,
     delete_old_room_messages,
     delete_user_room_messages,
     delete_all_user_room_messages,
     delete_user_messages,
     delete_old_messages,
     domain_admin_delete_room_messages_no_permission,
     domain_admin_delete_old_room_messages_no_permission,
     domain_admin_delete_user_messages_no_permission,
     domain_admin_delete_user_room_messages_no_permission,
     domain_admin_delete_old_messages_no_permission].

removed_users_tests() ->
    [removed_user_room_messages_are_deleted].

mam_not_configured_tests() ->
    [delete_room_messages_mam_not_configured,
     delete_user_messages_mam_not_configured].

init_per_suite(Config) ->
    case mam_helper:backend() of
        rdbms ->
            Config1 = dynamic_modules:save_modules(host_type(), Config),
            Config2 = ejabberd_node_utils:init(mim(), Config1),
            escalus:init_per_suite(Config2);
        _ ->
            {skip, "Deleting archived messages needs the rdbms MAM backend"}
    end.

end_per_suite(Config) ->
    dynamic_modules:restore_modules(Config),
    escalus:end_per_suite(Config).

init_per_group(admin_http, Config) ->
    graphql_helper:init_admin_handler(Config);
init_per_group(admin_cli, Config) ->
    graphql_helper:init_admin_cli(Config);
init_per_group(domain_admin, Config) ->
    graphql_helper:init_domain_admin_handler(Config);
init_per_group(GroupName, Config) when GroupName =:= admin_mam;
                                       GroupName =:= domain_admin_mam ->
    muc_helper:load_muc(),
    MAMOpts = mam_helper:config_opts(
                #{pm => #{},
                  muc => #{host => subhost_pattern(muc_helper:muc_host_pattern())},
                  async_writer => #{enabled => false}}),
    dynamic_modules:ensure_modules(host_type(), [{mod_mam, MAMOpts}]),
    Config;
init_per_group(removed_users, Config) ->
    muc_helper:load_muc(),
    MAMOpts = mam_helper:config_opts(
                #{pm => #{},
                  muc => #{host => subhost_pattern(muc_helper:muc_host_pattern()),
                           delete_messages_of_removed_users => true},
                  async_writer => #{enabled => false}}),
    dynamic_modules:ensure_modules(host_type(), [{mod_mam, MAMOpts}]),
    Config;
init_per_group(GroupName, Config) when GroupName =:= admin_mam_not_configured;
                                       GroupName =:= domain_admin_mam_not_configured ->
    muc_helper:load_muc(),
    dynamic_modules:ensure_modules(host_type(), [{mod_mam, stopped}]),
    Config.

end_per_group(GroupName, _Config) when GroupName =:= admin_http;
                                       GroupName =:= admin_cli;
                                       GroupName =:= domain_admin ->
    graphql_helper:clean();
end_per_group(_GroupName, _Config) ->
    muc_helper:unload_muc().

init_per_testcase(CaseName, Config) ->
    escalus:init_per_testcase(CaseName, Config).

end_per_testcase(CaseName, Config) ->
    escalus:end_per_testcase(CaseName, Config),
    escalus_fresh:clean().

%% Test cases

delete_room_messages(Config) ->
    Room = fresh_room_name(),
    OtherRoom = fresh_room_name(),
    put_room_msgs(Room),
    put_room_msgs(OtherRoom),
    Res = delete_room_messages(room_jid(Room), ?BEFORE, Config),
    ?assertEqual(2, get_ok_value(?ROOM_DELETE_PATH, Res)),
    ?assertEqual(1, room_archive_size(Room)),
    ?assertEqual(3, room_archive_size(OtherRoom)),
    %% Nothing left to delete
    Res2 = delete_room_messages(room_jid(Room), ?BEFORE, Config),
    ?assertEqual(0, get_ok_value(?ROOM_DELETE_PATH, Res2)).

delete_room_messages_from_empty_archive(Config) ->
    Res = delete_room_messages(room_jid(fresh_room_name()), ?BEFORE, Config),
    ?assertEqual(0, get_ok_value(?ROOM_DELETE_PATH, Res)).

delete_old_room_messages(Config) ->
    Room1 = fresh_room_name(),
    Room2 = fresh_room_name(),
    put_room_msgs(Room1),
    put_room_msgs(Room2),
    Res = delete_old_room_messages(muc_helper:muc_host(), ?BEFORE, Config),
    %% Other test cases may leave old messages in other rooms of the MUC service
    ?assert(get_ok_value(?OLD_ROOM_DELETE_PATH, Res) >= 4),
    ?assertEqual(1, room_archive_size(Room1)),
    ?assertEqual(1, room_archive_size(Room2)).

delete_user_room_messages(Config) ->
    escalus:fresh_story_with_config(Config, [{alice, 1}, {bob, 1}],
                                    fun delete_user_room_messages_story/3).

delete_user_room_messages_story(Config, Alice, Bob) ->
    Room1 = fresh_room_name(),
    Room2 = fresh_room_name(),
    [put_client_room_msgs(Room, Sender) || Room <- [Room1, Room2], Sender <- [Alice, Bob]],
    Res = delete_user_room_messages(escalus_client:short_jid(Alice), ?BEFORE, Config),
    ?assertEqual(4, get_ok_value(?USER_ROOM_DELETE_PATH, Res)),
    %% Alice's latest message and all of Bob's messages are left in each room
    ?assertEqual(4, room_archive_size(Room1)),
    ?assertEqual(4, room_archive_size(Room2)).

delete_all_user_room_messages(Config) ->
    escalus:fresh_story_with_config(Config, [{alice, 1}, {bob, 1}],
                                    fun delete_all_user_room_messages_story/3).

delete_all_user_room_messages_story(Config, Alice, Bob) ->
    Room = fresh_room_name(),
    put_client_room_msgs(Room, Alice),
    put_client_room_msgs(Room, Bob),
    Res = delete_user_room_messages(escalus_client:short_jid(Alice), null, Config),
    ?assertEqual(3, get_ok_value(?USER_ROOM_DELETE_PATH, Res)),
    ?assertEqual(3, room_archive_size(Room)).

removed_user_room_messages_are_deleted(Config) ->
    escalus:fresh_story_with_config(Config, [{alice, 1}, {bob, 1}],
                                    fun removed_user_room_messages_are_deleted_story/3).

removed_user_room_messages_are_deleted_story(_Config, Alice, Bob) ->
    Room = fresh_room_name(),
    put_client_room_msgs(Room, Alice),
    put_client_room_msgs(Room, Bob),
    {ok, _} = rpc_apply(mongoose_account_api, unregister_user,
                        [escalus_client:username(Alice), escalus_client:server(Alice)]),
    %% Only Bob's messages are left
    ?assertEqual(3, room_archive_size(Room)).

delete_user_messages(Config) ->
    escalus:fresh_story_with_config(Config, [{alice, 1}, {bob, 1}], fun delete_user_messages_story/3).

delete_user_messages_story(Config, Alice, Bob) ->
    put_msgs(Alice, Bob),
    Res = delete_user_messages(escalus_client:short_jid(Alice), ?BEFORE, Config),
    ?assertEqual(2, get_ok_value(?USER_DELETE_PATH, Res)),
    ?assertEqual(1, archive_size(Alice)),
    %% The other side of the conversation keeps its own copies
    ?assertEqual(3, archive_size(Bob)).

delete_old_messages(Config) ->
    escalus:fresh_story_with_config(Config, [{alice, 1}, {bob, 1}], fun delete_old_messages_story/3).

delete_old_messages_story(Config, Alice, Bob) ->
    put_msgs(Alice, Bob),
    Res = delete_old_messages(domain(), ?BEFORE, Config),
    ?assert(get_ok_value(?OLD_DELETE_PATH, Res) >= 4),
    ?assertEqual(1, archive_size(Alice)),
    ?assertEqual(1, archive_size(Bob)).

delete_room_messages_unknown_muc_server(Config) ->
    Res = delete_room_messages(<<"room@unknown.muc.server">>, ?BEFORE, Config),
    ?assertEqual(<<"muc_server_not_found">>, get_err_code(Res)).

delete_old_room_messages_unknown_muc_server(Config) ->
    Res = delete_old_room_messages(<<"unknown.muc.server">>, ?BEFORE, Config),
    ?assertEqual(<<"muc_server_not_found">>, get_err_code(Res)).

delete_user_messages_unknown_domain(Config) ->
    Res = delete_user_messages(<<"user@unknown-domain">>, ?BEFORE, Config),
    ?assertEqual(<<"domain_not_found">>, get_err_code(Res)).

delete_old_messages_unknown_domain(Config) ->
    Res = delete_old_messages(<<"unknown-domain">>, ?BEFORE, Config),
    ?assertEqual(<<"domain_not_found">>, get_err_code(Res)).

domain_admin_delete_room_messages_no_permission(Config) ->
    get_unauthorized(delete_room_messages(<<"room@muc.", (secondary_domain())/binary>>,
                                          ?BEFORE, Config)).

domain_admin_delete_old_room_messages_no_permission(Config) ->
    get_unauthorized(delete_old_room_messages(<<"muc.", (secondary_domain())/binary>>,
                                              ?BEFORE, Config)).

domain_admin_delete_user_messages_no_permission(Config) ->
    get_unauthorized(delete_user_messages(<<"user@", (secondary_domain())/binary>>,
                                          ?BEFORE, Config)).

domain_admin_delete_user_room_messages_no_permission(Config) ->
    get_unauthorized(delete_user_room_messages(<<"user@", (secondary_domain())/binary>>,
                                               ?BEFORE, Config)).

domain_admin_delete_old_messages_no_permission(Config) ->
    get_unauthorized(delete_old_messages(secondary_domain(), ?BEFORE, Config)).

delete_room_messages_mam_not_configured(Config) ->
    get_not_loaded(delete_room_messages(room_jid(fresh_room_name()), ?BEFORE, Config)).

delete_user_messages_mam_not_configured(Config) ->
    get_not_loaded(delete_user_messages(<<"user@", (domain())/binary>>, ?BEFORE, Config)).

%% Helpers

fresh_room_name() ->
    <<"mam-delete-", (binary:encode_hex(crypto:strong_rand_bytes(5), lowercase))/binary>>.

room_jid(Room) ->
    <<Room/binary, "@", (muc_helper:muc_host())/binary>>.

%% Archive one message from Alice to Bob on each of ?DATES, in both archives
put_msgs(Alice, Bob) ->
    AliceArc = make_arc_id(Alice),
    BobArc = make_arc_id(Bob),
    [mam_helper:put_msg(mam_helper:generate_msg_for_date_user(AliceArc, BobArc, DateTime))
     || DateTime <- ?DATES],
    mam_helper:wait_for_archive_size(Alice, 3),
    mam_helper:wait_for_archive_size(Bob, 3).

make_arc_id(Client) ->
    User = escalus_client:username(Client),
    Server = escalus_client:server(Client),
    Jid = mongoose_helper:make_jid(User, Server, <<>>),
    {escalus_client:short_jid(Client), Jid, rpc_apply(mod_mam_pm, archive_id, [Server, User])}.

archive_size(Client) ->
    rpc_apply(mod_mam_pm, archive_size,
              [escalus_client:server(Client), escalus_client:username(Client)]).

%% Archive one room message on each of ?DATES
put_room_msgs(Room) ->
    SenderJID = mongoose_helper:make_jid(<<"sender">>, domain(), <<"res">>),
    put_room_msgs(Room, SenderJID, <<"nick">>).

%% Archive one room message from the client on each of ?DATES
put_client_room_msgs(Room, Client) ->
    SenderJID = mongoose_helper:make_jid(escalus_client:username(Client),
                                         escalus_client:server(Client),
                                         escalus_client:resource(Client)),
    put_room_msgs(Room, SenderJID, escalus_client:username(Client)).

put_room_msgs(Room, SenderJID, Nick) ->
    MUCHost = muc_helper:muc_host(),
    RoomJID = mongoose_helper:make_jid(Room, MUCHost, <<>>),
    RoomArcID = rpc_apply(mod_mam_muc, archive_id, [MUCHost, Room]),
    SrcJID = mongoose_helper:make_jid(Room, MUCHost, Nick),
    Before = room_archive_size(Room),
    [ok = rpc_apply(mod_mam_muc, archive_message_for_ct,
                    [#{message_id => message_id(DateTime),
                       archive_id => RoomArcID,
                       local_jid => RoomJID,
                       remote_jid => SenderJID,
                       source_jid => SrcJID,
                       origin_id => none,
                       direction => incoming,
                       packet => escalus_stanza:groupchat_to(room_jid(Room), <<"Hi">>)}])
     || DateTime <- ?DATES],
    mam_helper:wait_for_room_archive_size(MUCHost, Room, Before + 3).

room_archive_size(Room) ->
    rpc_apply(mod_mam_muc, archive_size, [muc_helper:muc_host(), Room]).

message_id(DateTime) ->
    Seconds = calendar:datetime_to_gregorian_seconds(DateTime)
        - calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
    rpc_apply(mod_mam_utils, encode_compact_uuid, [Seconds * 1000000, 1]).

%% Commands

delete_room_messages(Room, Before, Config) ->
    Vars = #{<<"room">> => Room, <<"before">> => Before},
    execute_command(<<"mam">>, <<"deleteRoomMessages">>, Vars, Config).

delete_old_room_messages(MUCDomain, Before, Config) ->
    Vars = #{<<"mucDomain">> => MUCDomain, <<"before">> => Before},
    execute_command(<<"mam">>, <<"deleteOldRoomMessages">>, Vars, Config).

delete_user_room_messages(User, Before, Config) ->
    Vars = #{<<"user">> => User, <<"before">> => Before},
    execute_command(<<"mam">>, <<"deleteUserRoomMessages">>, Vars, Config).

delete_user_messages(User, Before, Config) ->
    Vars = #{<<"user">> => User, <<"before">> => Before},
    execute_command(<<"mam">>, <<"deleteUserMessages">>, Vars, Config).

delete_old_messages(Domain, Before, Config) ->
    Vars = #{<<"domain">> => Domain, <<"before">> => Before},
    execute_command(<<"mam">>, <<"deleteOldMessages">>, Vars, Config).
