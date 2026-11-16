-module(graphql_blocking_SUITE).

-compile([export_all, nowarn_export_all]).

-import(distributed_helper, [mim/0]).
-import(domain_helper, [domain/0, host_type/0]).
-import(graphql_helper, [execute_command/4, get_err_code/1, get_not_loaded/1, get_ok_value/2,
                         get_unauthorized/1, user_to_bin/1]).

-include_lib("stdlib/include/assert.hrl").

-define(NONEXISTING_DOMAIN, <<"abc@abc">>).
-define(NONEXISTING_USER, <<"abc@", (domain())/binary>>).

suite() ->
    distributed_helper:require_rpc_nodes([mim]) ++ escalus:suite().

all() ->
    [{group, admin_http},
     {group, admin_cli},
     {group, domain_admin}].

groups() ->
    [{admin_http, [], admin_groups()},
     {admin_cli, [], admin_groups()},
     {domain_admin, [], domain_admin_groups()},
     {admin_blocking, [parallel], admin_blocking_tests()},
     {admin_blocking_not_configured, [parallel], admin_blocking_not_configured_tests()},
     {domain_admin_blocking, [parallel], domain_admin_blocking_tests()}].

admin_groups() ->
    [{group, admin_blocking},
     {group, admin_blocking_not_configured}].

domain_admin_groups() ->
    [{group, domain_admin_blocking},
     {group, admin_blocking_not_configured}].

admin_blocking_tests() ->
    [admin_block_and_unblock,
     admin_block_with_session,
     admin_unblock_not_blocked,
     admin_block_without_jids,
     admin_blocking_nonexisting_user].

admin_blocking_not_configured_tests() ->
    [admin_get_blocking_list_not_configured,
     admin_block_not_configured].

domain_admin_blocking_tests() ->
    [domain_admin_get_blocking_list_no_permission,
     domain_admin_block_no_permission,
     domain_admin_unblock_no_permission,
     admin_block_and_unblock,
     admin_block_with_session].

%% Setup & Teardown

init_per_suite(Config) ->
    Config1 = ejabberd_node_utils:init(mim(), Config),
    Config2 = escalus:init_per_suite(Config1),
    dynamic_modules:save_modules(host_type(), Config2).

end_per_suite(Config) ->
    dynamic_modules:restore_modules(Config),
    escalus:end_per_suite(Config).

init_per_group(admin_http, Config) ->
    graphql_helper:init_admin_handler(Config);
init_per_group(admin_cli, Config) ->
    graphql_helper:init_admin_cli(Config);
init_per_group(domain_admin, Config) ->
    graphql_helper:init_domain_admin_handler(Config);
init_per_group(Group, Config) when Group == admin_blocking;
                                   Group == domain_admin_blocking ->
    Opts = config_parser_helper:mod_config_with_auto_backend(mod_blocking),
    dynamic_modules:ensure_modules(host_type(), [{mod_blocking, Opts}]),
    Config;
init_per_group(admin_blocking_not_configured, Config) ->
    dynamic_modules:ensure_modules(host_type(), [{mod_blocking, stopped}]),
    Config.

end_per_group(Group, _Config) when Group == admin_http;
                                   Group == admin_cli;
                                   Group == domain_admin ->
    graphql_helper:clean(),
    escalus_fresh:clean();
end_per_group(_Group, _Config) ->
    escalus_fresh:clean().

init_per_testcase(TestCase, Config) ->
    escalus:init_per_testcase(TestCase, Config).

end_per_testcase(TestCase, Config) ->
    escalus:end_per_testcase(TestCase, Config).

%% Admin

admin_block_and_unblock(Config) ->
    Config1 = escalus_fresh:create_users(Config, [{alice, 1}, {bob, 1}, {kate, 1}]),
    Alice = escalus_users:get_jid(Config1, alice),
    Bob = jid_prep(escalus_users:get_jid(Config1, bob)),
    Kate = jid_prep(escalus_users:get_jid(Config1, kate)),
    ?assertEqual([], get_ok_value([data, blocking, getBlockingList],
                                  get_blocking_list(Alice, Config1))),

    Res1 = block(Alice, [Bob, Kate], Config1),
    ?assertEqual([Bob, Kate], lists:sort(get_ok_value([data, blocking, block], Res1))),
    ?assertEqual([Bob, Kate], lists:sort(get_ok_value([data, blocking, getBlockingList],
                                                      get_blocking_list(Alice, Config1)))),

    Res2 = unblock(Alice, [Bob], Config1),
    ?assertEqual([Bob], get_ok_value([data, blocking, unblock], Res2)),
    ?assertEqual([Kate], get_ok_value([data, blocking, getBlockingList],
                                      get_blocking_list(Alice, Config1))).

%% The change is pushed to the user's sessions, and applied there right away
admin_block_with_session(Config) ->
    escalus:fresh_story_with_config(Config, [{alice, 1}, {bob, 1}],
                                    fun admin_block_with_session_story/3).

admin_block_with_session_story(Config, Alice, Bob) ->
    BobJid = escalus_utils:jid_to_lower(escalus_client:short_jid(Bob)),
    Res = block(Alice, [BobJid], Config),
    ?assertEqual([BobJid], get_ok_value([data, blocking, block], Res)),
    Push = escalus:wait_for_stanza(Alice),
    ?assert(mod_blocking_SUITE:is_xep191_push(<<"block">>, [BobJid], Push)),
    %% Bob's messages don't reach Alice
    escalus:send(Bob, escalus_stanza:chat_to(Alice, <<"Hi!">>)),
    escalus:assert(is_error, [<<"cancel">>, <<"service-unavailable">>],
                   escalus:wait_for_stanza(Bob)),
    escalus_assert:has_no_stanzas(Alice),

    Res2 = unblock(Alice, [BobJid], Config),
    ?assertEqual([BobJid], get_ok_value([data, blocking, unblock], Res2)),
    Push2 = escalus:wait_for_stanza(Alice),
    ?assert(mod_blocking_SUITE:is_xep191_push(<<"unblock">>, [BobJid], Push2)),
    escalus:send(Bob, escalus_stanza:chat_to(Alice, <<"Hi again!">>)),
    escalus:assert(is_chat_message, [<<"Hi again!">>], escalus:wait_for_stanza(Alice)).

admin_unblock_not_blocked(Config) ->
    Config1 = escalus_fresh:create_users(Config, [{alice, 1}]),
    Alice = escalus_users:get_jid(Config1, alice),
    Res = unblock(Alice, [<<"someone@", (domain())/binary>>], Config1),
    ?assertEqual([], get_ok_value([data, blocking, unblock], Res)).

admin_block_without_jids(Config) ->
    Config1 = escalus_fresh:create_users(Config, [{alice, 1}]),
    Alice = escalus_users:get_jid(Config1, alice),
    ?assertEqual(<<"bad_request">>, get_err_code(block(Alice, [], Config1))),
    ?assertEqual(<<"bad_request">>, get_err_code(unblock(Alice, [], Config1))).

admin_blocking_nonexisting_user(Config) ->
    Target = <<"someone@", (domain())/binary>>,
    ?assertEqual(<<"domain_not_found">>,
                 get_err_code(get_blocking_list(?NONEXISTING_DOMAIN, Config))),
    ?assertEqual(<<"user_not_found">>,
                 get_err_code(get_blocking_list(?NONEXISTING_USER, Config))),
    ?assertEqual(<<"domain_not_found">>,
                 get_err_code(block(?NONEXISTING_DOMAIN, [Target], Config))),
    ?assertEqual(<<"user_not_found">>,
                 get_err_code(block(?NONEXISTING_USER, [Target], Config))),
    ?assertEqual(<<"user_not_found">>,
                 get_err_code(unblock(?NONEXISTING_USER, [Target], Config))).

admin_get_blocking_list_not_configured(Config) ->
    get_not_loaded(get_blocking_list(<<"alice@", (domain())/binary>>, Config)).

admin_block_not_configured(Config) ->
    get_not_loaded(block(<<"alice@", (domain())/binary>>, [<<"bob@localhost">>], Config)).

%% Domain admin

domain_admin_get_blocking_list_no_permission(Config) ->
    escalus:fresh_story_with_config(Config, [{alice_bis, 1}],
                                    fun(Config1, Alice) ->
                                            get_unauthorized(get_blocking_list(Alice, Config1))
                                    end).

domain_admin_block_no_permission(Config) ->
    escalus:fresh_story_with_config(Config, [{alice_bis, 1}],
                                    fun(Config1, Alice) ->
                                            Res = block(Alice, [<<"bob@localhost">>], Config1),
                                            get_unauthorized(Res)
                                    end).

domain_admin_unblock_no_permission(Config) ->
    escalus:fresh_story_with_config(Config, [{alice_bis, 1}],
                                    fun(Config1, Alice) ->
                                            Res = unblock(Alice, [<<"bob@localhost">>], Config1),
                                            get_unauthorized(Res)
                                    end).

%% Helpers

get_blocking_list(User, Config) ->
    Vars = #{user => user_to_bin(User)},
    execute_command(<<"blocking">>, <<"getBlockingList">>, Vars, Config).

block(User, JIDs, Config) ->
    Vars = #{user => user_to_bin(User), jids => JIDs},
    execute_command(<<"blocking">>, <<"block">>, Vars, Config).

unblock(User, JIDs, Config) ->
    Vars = #{user => user_to_bin(User), jids => JIDs},
    execute_command(<<"blocking">>, <<"unblock">>, Vars, Config).

jid_prep(JID) ->
    jid:to_binary(jid:from_binary(JID)).
