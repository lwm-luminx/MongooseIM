-module(auth_jwt_SUITE).
-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").

-define(DOMAIN, <<"localhost">>).
-define(HOST_TYPE, <<"test host type">>).
-define(USERNAME, <<"10857839">>).
-define(WRONG_USERNAME, <<"alice">>).
-define(JWT_KEY, <<"testtesttest">>).
-define(OLD_KEY, <<"old key">>).
-define(NEW_KEY, <<"new key">>).
%%--------------------------------------------------------------------
%% Suite configuration
%%--------------------------------------------------------------------

all() ->
    [{group, generic}, {group, public_key}, {group, multiple_keys}, {group, claims},
     {group, env_secret}].

groups() ->
    [
     {generic, [parallel], generic_tests()},
     {public_key, [], public_key_tests()},
     {multiple_keys, [parallel], multiple_keys_tests()},
     {claims, [parallel], claims_tests()},
     {env_secret, [], env_secret_tests()}
    ].

generic_tests() ->
    [
     check_password_succeeds_for_correct_token,
     check_password_fails_for_wrong_token,
     check_password_fails_for_correct_token_but_wrong_username,
     authorize,
     does_user_exist,
     remove_user_returns_ok,
     supported_sasl_mechanisms
    ].

public_key_tests() ->
    [
     check_password_succeeds_for_pubkey_signed_token
    ].

multiple_keys_tests() ->
    [
     check_password_succeeds_for_any_key_without_kid,
     check_password_uses_key_with_matching_kid,
     check_password_fails_for_unknown_kid,
     check_password_fails_for_unknown_key,
     check_password_fails_for_malformed_token
    ].

claims_tests() ->
    [
     check_password_succeeds_for_matching_claims,
     check_password_succeeds_for_audience_list,
     check_password_fails_for_wrong_issuer,
     check_password_fails_for_wrong_audience,
     check_password_fails_for_wrong_domain,
     check_password_fails_for_missing_claims
    ].

env_secret_tests() ->
    [
     check_password_reads_secret_from_env,
     check_password_fails_when_env_var_is_not_set
    ].

suite() ->
    [].

%%--------------------------------------------------------------------
%% Init & teardown
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    application:ensure_all_started(jid),
    meck:new(ejabberd_auth, [no_link, passthrough]),
    meck:expect(ejabberd_auth, auth_modules_for_host_type,
                fun(_) -> [] end),
    Config.

end_per_suite(Config) ->
    unset_auth_opts(),
    meck:unload(ejabberd_auth),
    Config.

init_per_group(public_key, Config) ->
    Root = small_path_helper:repo_dir(Config),
    PrivkeyPath = filename:join([Root, "tools", "ssl", "mongooseim", "privkey.pem"]),
    PubkeyPath = filename:join([Root, "tools", "ssl", "mongooseim", "pubkey.pem"]),
    {ok, PrivKey} = file:read_file(PrivkeyPath),
    set_auth_opts({file, PubkeyPath}, rs256, bookingNumber),
    ok = ejabberd_auth_jwt:start(?HOST_TYPE),
    [{priv_key, PrivKey} | Config];
init_per_group(multiple_keys, Config) ->
    set_jwt_opts(#{username_key => bookingNumber,
                   keys => [#{kid => <<"old">>, algorithm => hs256, secret => {value, ?OLD_KEY}},
                            #{kid => <<"new">>, algorithm => hs256, secret => {value, ?NEW_KEY}}]}),
    ok = ejabberd_auth_jwt:start(?HOST_TYPE),
    Config;
init_per_group(claims, Config) ->
    set_jwt_opts(#{secret => {value, ?JWT_KEY}, algorithm => hs256,
                   username_key => bookingNumber, domain_key => domain,
                   issuer => <<"https://issuer.example.com">>, audience => <<"chat">>}),
    ok = ejabberd_auth_jwt:start(?HOST_TYPE),
    Config;
init_per_group(env_secret, Config) ->
    set_auth_opts({env, "JWT_TEST_SECRET"}, hs256, bookingNumber),
    ok = ejabberd_auth_jwt:start(?HOST_TYPE),
    Config;
init_per_group(_, Config) ->
    set_auth_opts({value, ?JWT_KEY}, hs256, bookingNumber),
    ok = ejabberd_auth_jwt:start(?HOST_TYPE),
    Config.

end_per_group(_, Config) ->
    ok = ejabberd_auth_jwt:stop(?HOST_TYPE),
    Config.


init_per_testcase(_CaseName, Config) ->
    Config.

end_per_testcase(_CaseName, Config) ->
    Config.

%%--------------------------------------------------------------------
%% Authentication tests
%%--------------------------------------------------------------------

check_password_succeeds_for_correct_token(_Config) ->
    true = ejabberd_auth_jwt:check_password(?HOST_TYPE, ?USERNAME, ?DOMAIN,
                                            generate_token(hs256, 0, ?JWT_KEY)).

check_password_fails_for_wrong_token(_C) ->
    false = ejabberd_auth_jwt:check_password(?HOST_TYPE, ?USERNAME, ?DOMAIN,
                                             generate_token(hs256, 60, ?JWT_KEY)).

check_password_fails_for_correct_token_but_wrong_username(_C) ->
    false = ejabberd_auth_jwt:check_password(?HOST_TYPE, ?WRONG_USERNAME, ?DOMAIN,
                                             generate_token(hs256, 0, ?JWT_KEY)).

authorize(_C) ->
    Creds0 = mongoose_credentials:new(?DOMAIN, ?HOST_TYPE, #{}),
    Creds = mongoose_credentials:extend(Creds0, [{username, ?USERNAME},
                                                 {password, generate_token(hs256, 0, ?JWT_KEY)},
                                                 {digest, fake},
                                                 {digest_gen, fun(A) -> A end}]),
    {ok, Creds2} = ejabberd_auth_jwt:authorize(Creds),
    ejabberd_auth_jwt = mongoose_credentials:get(Creds2, auth_module).

does_user_exist(_Config) ->
    true = ejabberd_auth_jwt:does_user_exist(?HOST_TYPE, <<"madhatter">>, ?DOMAIN).

remove_user_returns_ok(_Config) ->
    ok = ejabberd_auth_jwt:remove_user(?HOST_TYPE, <<"alice">>, ?DOMAIN).

supported_sasl_mechanisms(_C) ->
    Modules = [cyrsasl_plain, cyrsasl_digest, cyrsasl_external,
               cyrsasl_scram_sha1, cyrsasl_scram_sha224, cyrsasl_scram_sha256,
               cyrsasl_scram_sha384, cyrsasl_scram_sha512],
    [true, false, false, false, false, false, false, false] =
        [ejabberd_auth_jwt:supports_sasl_module(?DOMAIN, Mod) || Mod <- Modules].

check_password_succeeds_for_pubkey_signed_token(C) ->
    Key = proplists:get_value(priv_key, C),
    true = ejabberd_auth_jwt:check_password(?HOST_TYPE, ?USERNAME, ?DOMAIN,
                                            generate_token(rs256, 0, Key)).

check_password_succeeds_for_any_key_without_kid(_C) ->
    true = check_token(make_token(#{}, claims(), ?OLD_KEY)),
    true = check_token(make_token(#{}, claims(), ?NEW_KEY)).

check_password_uses_key_with_matching_kid(_C) ->
    true = check_token(make_token(#{kid => <<"new">>}, claims(), ?NEW_KEY)),
    true = check_token(make_token(#{kid => <<"old">>}, claims(), ?OLD_KEY)),
    false = check_token(make_token(#{kid => <<"new">>}, claims(), ?OLD_KEY)).

check_password_fails_for_unknown_kid(_C) ->
    false = check_token(make_token(#{kid => <<"other">>}, claims(), ?NEW_KEY)).

check_password_fails_for_unknown_key(_C) ->
    false = check_token(make_token(#{}, claims(), <<"some other key">>)).

check_password_fails_for_malformed_token(_C) ->
    [false = check_token(Token) || Token <- [<<>>, <<"abc">>, <<"a.b">>, <<"a.b.c">>,
                                             <<"!!!.???.***">>]].

check_password_succeeds_for_matching_claims(_C) ->
    true = check_token(make_token(#{}, full_claims(#{}), ?JWT_KEY)).

check_password_succeeds_for_audience_list(_C) ->
    true = check_token(make_token(#{}, full_claims(#{aud => [<<"web">>, <<"chat">>]}), ?JWT_KEY)).

check_password_fails_for_wrong_issuer(_C) ->
    false = check_token(make_token(#{}, full_claims(#{iss => <<"https://evil.example.com">>}),
                                   ?JWT_KEY)).

check_password_fails_for_wrong_audience(_C) ->
    false = check_token(make_token(#{}, full_claims(#{aud => <<"web">>}), ?JWT_KEY)),
    false = check_token(make_token(#{}, full_claims(#{aud => [<<"web">>]}), ?JWT_KEY)).

check_password_fails_for_wrong_domain(_C) ->
    false = check_token(make_token(#{}, full_claims(#{domain => <<"other.example.com">>}),
                                   ?JWT_KEY)).

check_password_fails_for_missing_claims(_C) ->
    [false = check_token(make_token(#{}, maps:remove(Claim, full_claims(#{})), ?JWT_KEY))
     || Claim <- [iss, aud, domain, bookingNumber]].

check_password_reads_secret_from_env(_C) ->
    os:putenv("JWT_TEST_SECRET", binary_to_list(?JWT_KEY)),
    try
        true = check_token(generate_token(hs256, 0, ?JWT_KEY))
    after
        os:unsetenv("JWT_TEST_SECRET")
    end.

check_password_fails_when_env_var_is_not_set(_C) ->
    false = check_token(generate_token(hs256, 0, ?JWT_KEY)).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

check_token(Token) ->
    ejabberd_auth_jwt:check_password(?HOST_TYPE, ?USERNAME, ?DOMAIN, Token).

claims() ->
    Now = erlang:system_time(second),
    #{bookingNumber => ?USERNAME, exp => Now + 60, iat => Now}.

full_claims(Extra) ->
    maps:merge(claims(), maps:merge(#{iss => <<"https://issuer.example.com">>,
                                      aud => <<"chat">>,
                                      domain => ?DOMAIN}, Extra)).

%% jwerl:sign/3 can't set the 'kid' header, so HS256 tokens are built here
make_token(ExtraHeader, Claims, Key) ->
    Header = base64url(jsx:encode(maps:merge(#{alg => <<"HS256">>, typ => <<"JWT">>}, ExtraHeader))),
    Payload = base64url(jsx:encode(Claims)),
    Input = <<Header/binary, ".", Payload/binary>>,
    Signature = base64url(crypto:mac(hmac, sha256, Key, Input)),
    <<Input/binary, ".", Signature/binary>>.

base64url(Bin) ->
    base64:encode(Bin, #{mode => urlsafe, padding => false}).

set_jwt_opts(Opts) ->
    mongoose_config:set_opts(#{{auth, ?HOST_TYPE} => #{jwt => Opts}}).

set_auth_opts(Secret, Algorithm, Key) ->
    mongoose_config:set_opts(#{{auth, ?HOST_TYPE} => #{jwt => #{secret => Secret,
                                                                algorithm => Algorithm,
                                                                username_key => Key}}}).

unset_auth_opts() ->
    mongoose_config:erase_opts().

generate_token(Alg, NbfDelta, Key) ->
    Now = erlang:system_time(second),
    Data = #{bookingNumber => ?USERNAME,
             exp => Now + 60,
             nbf => Now + NbfDelta,
             iat => Now},
    jwerl:sign(Data, Alg, Key).
