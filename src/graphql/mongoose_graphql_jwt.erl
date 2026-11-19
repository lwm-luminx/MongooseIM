%% @doc Verification of JSON Web Tokens presented as `Authorization: Bearer <token>'
%% to the admin and domain admin GraphQL endpoints.
%%
%% The tokens are verified with the keys configured for the listener. The keys
%% are tried in order. If the token header has a `kid', only the keys with
%% the same `kid' and the keys without one are tried.
%% The `exp' and `aud' claims are required. `aud' has to contain the configured audience,
%% so that tokens issued for other services (such as XMPP clients) can't be used here,
%% even when they are signed with the same key. `iss' is checked when configured.
%% @end
-module(mongoose_graphql_jwt).

-export([config_spec/0,
         process_config/1,
         process_secret/1,
         process_algorithm/1,
         read_keys/1,
         verify/2,
         get_claim/2,
         expires_at/1]).

-include("mongoose_config_spec.hrl").

-type algorithm() :: mongoose_jwt:algorithm().
-type secret() :: binary() | {env, string()}.
-type key() :: #{kid := binary() | undefined,
                 algorithm := algorithm(),
                 secret := secret()}.
-type opts() :: #{keys := [map()],
                  issuer => binary(),
                  audience := binary(),
                  domain_key => binary()}.
-type claims() :: mongoose_jwt:claims().

-export_type([opts/0, claims/0]).

%% Config

-spec config_spec() -> mongoose_config_spec:config_section().
config_spec() ->
    #section{
       items = #{<<"keys">> => #list{items = key_config_spec(),
                                     validate = non_empty},
                 <<"issuer">> => #option{type = binary,
                                         validate = non_empty},
                 <<"audience">> => #option{type = binary,
                                           validate = non_empty},
                 <<"domain_key">> => #option{type = binary,
                                             validate = non_empty}},
       defaults = #{<<"domain_key">> => <<"domain">>},
       required = [<<"keys">>, <<"audience">>]
      }.

key_config_spec() ->
    #section{
       items = #{<<"kid">> => #option{type = binary,
                                      validate = non_empty},
                 <<"secret">> => secret_config_spec(),
                 <<"algorithm">> => #option{type = binary,
                                            validate = {enum, maps:keys(mongoose_jwt:algorithms())},
                                            process = fun ?MODULE:process_algorithm/1}},
       required = [<<"secret">>, <<"algorithm">>]
      }.

secret_config_spec() ->
    #section{
       items = #{<<"file">> => #option{type = string,
                                       validate = filename},
                 <<"env">> => #option{type = string,
                                      validate = non_empty},
                 <<"value">> => #option{type = binary,
                                        validate = non_empty}},
       format_items = list,
       process = fun ?MODULE:process_secret/1
      }.

-spec process_secret([{file | env | value, string() | binary()}]) ->
          {file | env | value, string() | binary()}.
process_secret([Item]) -> Item;
process_secret(_Items) ->
    %% The values are not included, as they are secret
    error(#{what => one_secret_source_required}).

-spec process_algorithm(binary()) -> algorithm().
process_algorithm(Alg) -> maps:get(Alg, mongoose_jwt:algorithms()).

%% @doc Validates the JWT options of a GraphQL listener.
-spec process_config(map()) -> ok.
process_config(#{jwt := _, schema_endpoint := user}) ->
    error(#{what => jwt_not_supported_for_user_endpoint,
            text => <<"Use an auth method of the user's host type, e.g. auth.jwt">>});
process_config(_) ->
    ok.

%% @doc Reads the configured secrets. Files are read once,
%% environment variables are read for each request.
-spec read_keys(opts()) -> [key()].
read_keys(#{keys := Keys}) ->
    [read_key(Key#{kid => maps:get(kid, Key, undefined)}) || Key <- Keys].

read_key(#{kid := Kid, algorithm := Alg, secret := Secret}) ->
    Value = read_secret(Secret, Kid),
    check_key(Value, Alg, Kid),
    #{kid => Kid, algorithm => Alg, secret => Value}.

read_secret({value, Secret}, _Kid) -> Secret;
read_secret({env, Var}, _Kid) -> {env, Var};
read_secret({file, Path}, Kid) ->
    case file:read_file(Path) of
        {ok, <<>>} -> error(#{what => graphql_jwt_secret_file_empty, path => Path, kid => Kid});
        {ok, Secret} -> Secret;
        {error, Reason} -> error(#{what => graphql_jwt_secret_file_unreadable, path => Path,
                                   kid => Kid, reason => Reason})
    end.

%% The RS and ES algorithms need a public key. Environment variables are checked when used.
check_key({env, _}, _Alg, _Kid) ->
    ok;
check_key(_Secret, Alg, _Kid) when Alg =:= hs256; Alg =:= hs384; Alg =:= hs512 ->
    ok;
check_key(Secret, Alg, Kid) ->
    case mongoose_jwt:is_public_key(Secret) of
        true -> ok;
        false -> error(#{what => graphql_jwt_public_key_required, algorithm => Alg, kid => Kid,
                         text => <<"RS and ES algorithms need one PEM-encoded public key">>})
    end.

%% Verification

%% @doc Verifies the token signature and the claims.
%% The token itself is never logged, because it is a credential.
-spec verify(binary(), #{jwt := opts(), jwt_keys := [key()], atom() => term()}) ->
          {ok, claims()} | {error, atom()}.
verify(Token, #{jwt := Opts, jwt_keys := Keys}) ->
    case verify_signature(Token, Keys) of
        {ok, Claims} ->
            case check_claims(Claims, Opts) of
                ok -> {ok, Claims};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

verify_signature(Token, Keys) ->
    case mongoose_jwt:header(Token) of
        {ok, Header} ->
            Kid = maps:get(<<"kid">>, Header, undefined),
            verify_with_keys(Token, matching_keys(Kid, Keys), {error, no_matching_key});
        {error, _} = Error ->
            Error
    end.

%% A 'kid' that is not a string is malformed (RFC 7515, section 4.1.4), and matches no key
matching_keys(undefined, Keys) ->
    Keys;
matching_keys(Kid, Keys) when is_binary(Kid) ->
    [Key || Key = #{kid := KeyKid} <- Keys, KeyKid =:= Kid orelse KeyKid =:= undefined];
matching_keys(_, _Keys) ->
    [].

verify_with_keys(_Token, [], LastError) ->
    LastError;
verify_with_keys(Token, [#{algorithm := Alg, secret := Secret} | Keys], _LastError) ->
    Result = case secret_value(Secret) of
                 {ok, Key} -> mongoose_jwt:verify(Token, Alg, Key);
                 error -> {error, secret_not_set}
             end,
    case Result of
        {ok, Claims} -> {ok, Claims};
        {error, _} = Error -> verify_with_keys(Token, Keys, Error)
    end.

%% An empty secret is treated as unset, because anyone could sign tokens with it
secret_value({env, Var}) ->
    case os:getenv(Var) of
        false -> error;
        "" -> error;
        Value -> {ok, list_to_binary(Value)}
    end;
secret_value(Secret) when is_binary(Secret) ->
    {ok, Secret}.

%% mongoose_jwt checks 'exp' only when it is present, but admin tokens must expire
check_claims(Claims, Opts = #{audience := Audience}) ->
    Checks = [{<<"exp">>, fun is_number/1, missing_expiration},
              {<<"aud">>, fun(Aud) -> has_audience(Aud, Audience) end, wrong_audience}]
        ++ [{<<"iss">>, fun(Iss) -> Iss =:= Issuer end, wrong_issuer}
            || Issuer <- [maps:get(issuer, Opts, undefined)], Issuer =/= undefined],
    check_claims_loop(Claims, Checks).

check_claims_loop(_Claims, []) ->
    ok;
check_claims_loop(Claims, [{Name, Pred, Error} | Checks]) ->
    case Pred(get_claim(Name, Claims)) of
        true -> check_claims_loop(Claims, Checks);
        false -> {error, Error}
    end.

%% The 'aud' claim can be a string or a list of strings (RFC 7519)
has_audience(Audience, Audience) -> true;
has_audience(Auds, Audience) when is_list(Auds) -> lists:member(Audience, Auds);
has_audience(_, _) -> false.

%% @doc Returns a claim value, or `undefined'.
-spec get_claim(binary(), claims()) -> term().
get_claim(Name, Claims) ->
    maps:get(Name, Claims, undefined).

%% @doc The expiration time of a verified token, in seconds since the epoch.
-spec expires_at(claims()) -> integer().
expires_at(#{<<"exp">> := Exp}) ->
    trunc(Exp).
