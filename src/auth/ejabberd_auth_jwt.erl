%%%----------------------------------------------------------------------
%%% File    : ejabberd_auth_jwt.erl
%%% Author  : Astro <astro@spaceboyz.net>
%%% Purpose : Authentification with JSON Web Tokens
%%% Created : 02 Aug 2016 by Stephan Maka <stephan@spaceboyz.net>
%%%
%%%
%%% MongooseIM, Copyright (C) 2016   CostaDigital
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
%%%
%%%----------------------------------------------------------------------

-module(ejabberd_auth_jwt).
-author('astro@spaceboyz.net').

%% External exports
-behaviour(mongoose_gen_auth).

-export([start/1,
         stop/1,
         config_spec/0,
         authorize/1,
         check_password/4,
         check_password/6,
         does_user_exist/3,
         remove_user/3,
         supports_sasl_module/2,
         supported_features/0
        ]).

%% Config spec callbacks
-export([process_jwt_secret/1, process_algorithm/1, process_jwt_opts/1]).

-include("mongoose.hrl").
-include("mongoose_config_spec.hrl").

-type algorithm() :: hs256 | rs256 | es256 | hs384 | rs384 | es384 | hs512 | rs512 | es512.
-type secret() :: binary() | {env, string()}.
-type key() :: #{kid := binary() | undefined, algorithm := algorithm(), secret := secret()}.

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec start(HostType :: mongooseim:host_type()) -> ok.
start(HostType) ->
    persistent_term:put({?MODULE, HostType, keys}, read_keys(HostType)),
    ok.

-spec stop(HostType :: mongooseim:host_type()) -> ok.
stop(HostType) ->
    persistent_term:erase({?MODULE, HostType, keys}),
    ok.

-spec config_spec() -> mongoose_config_spec:config_section().
config_spec() ->
    #section{
       items = #{<<"secret">> => jwt_secret_config_spec(),
                 <<"algorithm">> => algorithm_config_spec(),
                 <<"keys">> => #list{items = jwt_key_config_spec(),
                                     validate = unique_non_empty},
                 <<"username_key">> => #option{type = atom,
                                               validate = non_empty},
                 <<"domain_key">> => #option{type = atom,
                                             validate = non_empty},
                 <<"issuer">> => #option{type = binary,
                                         validate = non_empty},
                 <<"audience">> => #option{type = binary,
                                           validate = non_empty}
                },
       required = [<<"username_key">>],
       process = fun ?MODULE:process_jwt_opts/1
      }.

jwt_key_config_spec() ->
    #section{
       items = #{<<"kid">> => #option{type = binary,
                                      validate = non_empty},
                 <<"secret">> => jwt_secret_config_spec(),
                 <<"algorithm">> => algorithm_config_spec()},
       required = [<<"secret">>, <<"algorithm">>]
      }.

algorithm_config_spec() ->
    #option{type = binary,
            validate = {enum, maps:keys(algorithms())},
            process = fun ?MODULE:process_algorithm/1}.

jwt_secret_config_spec() ->
    #section{
       items = #{<<"file">> => #option{type = string,
                                       validate = filename},
                 <<"env">> => #option{type = string,
                                      validate = non_empty},
                 <<"value">> => #option{type = binary}},
       format_items = list,
       process = fun ?MODULE:process_jwt_secret/1
      }.

process_jwt_secret([V]) -> V.

process_algorithm(Alg) -> maps:get(Alg, algorithms()).

%% Either a single key ('secret' with 'algorithm'), or a list of 'keys', or both.
process_jwt_opts(Opts = #{secret := _, algorithm := _}) -> Opts;
process_jwt_opts(#{secret := _}) -> error(#{what => jwt_algorithm_missing});
process_jwt_opts(#{algorithm := _}) -> error(#{what => jwt_secret_missing});
process_jwt_opts(Opts = #{keys := [_ | _]}) -> Opts;
process_jwt_opts(_) -> error(#{what => jwt_secret_missing}).

-spec supports_sasl_module(binary(), cyrsasl:sasl_module()) -> boolean().
supports_sasl_module(_, Module) -> Module =:= cyrsasl_plain.

-spec authorize(mongoose_credentials:t()) -> {ok, mongoose_credentials:t()}
                                           | {error, any()}.
authorize(Creds) ->
    ejabberd_auth:authorize_with_check_password(?MODULE, Creds).

-spec check_password(HostType :: mongooseim:host_type(),
                     LUser :: jid:luser(),
                     LServer :: jid:lserver(),
                     Password :: binary()) -> boolean().
check_password(HostType, LUser, LServer, Password) ->
    Opts = mongoose_config:get_opt([{auth, HostType}, jwt]),
    case verify_token(HostType, Password) of
        {ok, TokenData} ->
            case check_claims(TokenData, LUser, LServer, Opts) of
                ok ->
                    ?LOG_INFO(#{what => jwt_success_auth,
                                text => <<"Successfully authenticated with JWT">>,
                                user => LUser, server => LServer}),
                    true;
                {error, Reason} ->
                    %% The claims are not logged, as they might contain personal data
                    ?LOG_WARNING(#{what => jwt_claims_check_failed,
                                   text => <<"JWT claims do not match the user">>,
                                   reason => Reason, user => LUser, server => LServer}),
                    false
            end;
        {error, Reason} ->
            ?LOG_WARNING(#{what => jwt_verification_failed,
                           text => <<"Cannot verify JWT for user">>,
                           reason => Reason,
                           user => LUser, server => LServer}),
            false
    end.

-spec check_password(HostType :: mongooseim:host_type(),
                     LUser :: jid:luser(),
                     LServer :: jid:lserver(),
                     Password :: binary(),
                     Digest :: binary(),
                     DigestGen :: fun()) -> boolean().
check_password(HostType, LUser, LServer, Password, _Digest, _DigestGen) ->
    check_password(HostType, LUser, LServer, Password).

-spec does_user_exist(HostType :: mongooseim:host_type(),
                      LUser :: jid:luser(),
                      LServer :: jid:lserver()) -> boolean() | {error, atom()}.
does_user_exist(_HostType, _LUser, _LServer) ->
    true.

%% User records are not kept in MongooseIM for this backend, but this callback
%% lets the remove_user hook run, so the user's associated data can be removed.
-spec remove_user(mongooseim:host_type(), jid:luser(), jid:lserver()) -> ok.
remove_user(_HostType, _LUser, _LServer) ->
    ok.

-spec supported_features() -> [atom()].
supported_features() -> [dynamic_domains].

%%%----------------------------------------------------------------------
%%% Internal helpers
%%%----------------------------------------------------------------------

%% @doc Tries the configured keys in order. If the token header has a 'kid',
%% only the keys with that 'kid' and the keys without one are tried.
-spec verify_token(mongooseim:host_type(), binary()) -> {ok, map()} | {error, term()}.
verify_token(HostType, Token) ->
    try jwerl:header(Token) of
        Header when is_map(Header) ->
            Keys = matching_keys(maps:get(kid, Header, undefined),
                                 persistent_term:get({?MODULE, HostType, keys})),
            verify_with_keys(Token, Keys, {error, no_matching_key});
        _ ->
            {error, invalid_token}
    catch _:_ ->
            {error, invalid_token}
    end.

-spec matching_keys(binary() | undefined, [key()]) -> [key()].
matching_keys(Kid, Keys) when is_binary(Kid) ->
    [Key || Key = #{kid := KeyKid} <- Keys, KeyKid =:= Kid orelse KeyKid =:= undefined];
matching_keys(_, Keys) ->
    Keys.

-spec verify_with_keys(binary(), [key()], {error, term()}) -> {ok, map()} | {error, term()}.
verify_with_keys(_Token, [], LastError) ->
    LastError;
verify_with_keys(Token, [#{algorithm := Alg, secret := Secret} | Keys], _LastError) ->
    Result = case secret_value(Secret) of
                 {ok, Key} ->
                     %% Errors are not logged, as they could contain the token
                     try jwerl:verify(Token, Alg, Key)
                     catch _:_ -> {error, invalid_token}
                     end;
                 {error, _} = SecretError ->
                     SecretError
             end,
    case Result of
        {ok, TokenData} when is_map(TokenData) -> {ok, TokenData};
        {error, _} = Error -> verify_with_keys(Token, Keys, Error);
        _ -> verify_with_keys(Token, Keys, {error, invalid_token})
    end.

-spec secret_value(secret()) -> {ok, binary()} | {error, {env_var_not_set, string()}}.
secret_value({env, Var}) ->
    case os:getenv(Var) of
        false -> {error, {env_var_not_set, Var}};
        Value -> {ok, list_to_binary(Value)}
    end;
secret_value(Key) when is_binary(Key) ->
    {ok, Key}.

-spec check_claims(map(), jid:luser(), jid:lserver(), map()) -> ok | {error, atom()}.
check_claims(TokenData, LUser, LServer, Opts = #{username_key := UserKey}) ->
    Checks = [{UserKey, {equal, LUser}, wrong_user}]
        ++ [{DomainKey, {equal, LServer}, wrong_domain}
            || DomainKey <- [maps:get(domain_key, Opts, undefined)], DomainKey =/= undefined]
        ++ [{iss, {equal, Issuer}, wrong_issuer}
            || Issuer <- [maps:get(issuer, Opts, undefined)], Issuer =/= undefined]
        ++ [{aud, {contains, Audience}, wrong_audience}
            || Audience <- [maps:get(audience, Opts, undefined)], Audience =/= undefined],
    check_claims(TokenData, Checks).

check_claims(_TokenData, []) ->
    ok;
check_claims(TokenData, [{Claim, Expected, Error} | Checks]) ->
    case claim_matches(get_claim(Claim, TokenData), Expected) of
        true -> check_claims(TokenData, Checks);
        false -> {error, Error}
    end.

%% jwerl decodes claim names to existing atoms only
get_claim(Claim, TokenData) ->
    case maps:find(Claim, TokenData) of
        {ok, Value} -> Value;
        error -> maps:get(atom_to_binary(Claim), TokenData, undefined)
    end.

%% The 'aud' claim can be a string or a list of strings (RFC 7519)
claim_matches(Value, {equal, Value}) -> true;
claim_matches(Value, {contains, Value}) -> true;
claim_matches(Values, {contains, Value}) when is_list(Values) -> lists:member(Value, Values);
claim_matches(_, _) -> false.

%% The keys from 'secret' and 'keys'. A file is read only once during startup,
%% and an environment variable is read on every auth request.
-spec read_keys(mongooseim:host_type()) -> [key()].
read_keys(HostType) ->
    Opts = mongoose_config:get_opt([{auth, HostType}, jwt]),
    SingleKey = case Opts of
                    #{secret := Secret, algorithm := Alg} ->
                        [#{kid => undefined, algorithm => Alg, secret => read_secret(Secret)}];
                    #{} ->
                        []
                end,
    SingleKey ++ [#{kid => maps:get(kid, Key, undefined),
                    algorithm => Alg,
                    secret => read_secret(Secret)}
                  || Key = #{algorithm := Alg, secret := Secret} <- maps:get(keys, Opts, [])].

-spec read_secret({value, binary()} | {env, string()} | {file, string()}) -> secret().
read_secret({value, Secret}) ->
    Secret;
read_secret({env, Env}) ->
    {env, Env};
read_secret({file, Path}) ->
    {ok, Secret} = file:read_file(Path),
    Secret.

%% Explicit mapping, because the atoms are owned by jwerl and might not exist yet
-spec algorithms() -> #{binary() => algorithm()}.
algorithms() ->
    #{<<"HS256">> => hs256, <<"RS256">> => rs256, <<"ES256">> => es256,
      <<"HS384">> => hs384, <<"RS384">> => rs384, <<"ES384">> => es384,
      <<"HS512">> => hs512, <<"RS512">> => rs512, <<"ES512">> => es512}.
