%% @doc Verification of JSON Web Tokens presented as `Authorization: Bearer <token>'
%% to the admin and domain admin GraphQL endpoints.
%%
%% The tokens are verified with the keys configured for the listener. The keys
%% are tried in order. If the token header has a `kid', only the keys with
%% the same `kid' and the keys without one are tried.
%% The `exp' claim is required, and `iss' and `aud' are checked when configured.
%% @end
-module(mongoose_graphql_jwt).

-export([config_spec/0,
         process_config/1,
         process_secret/1,
         process_algorithm/1,
         read_keys/1,
         verify/2,
         get_claim/2]).

-include("mongoose_config_spec.hrl").

-type algorithm() :: hs256 | rs256 | es256 | hs384 | rs384 | es384 | hs512 | rs512 | es512.
-type secret() :: binary() | {env, string()}.
-type key() :: #{kid := binary() | undefined,
                 algorithm := algorithm(),
                 secret := secret()}.
-type opts() :: #{keys := [map()],
                  issuer => binary(),
                  audience => binary(),
                  domain_key => binary()}.
-type claims() :: #{atom() | binary() => term()}.

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
       required = [<<"keys">>]
      }.

key_config_spec() ->
    #section{
       items = #{<<"kid">> => #option{type = binary,
                                      validate = non_empty},
                 <<"secret">> => secret_config_spec(),
                 <<"algorithm">> => #option{type = binary,
                                            validate = {enum, maps:keys(algorithms())},
                                            process = fun ?MODULE:process_algorithm/1}},
       required = [<<"secret">>, <<"algorithm">>]
      }.

secret_config_spec() ->
    #section{
       items = #{<<"file">> => #option{type = string,
                                       validate = filename},
                 <<"env">> => #option{type = string,
                                      validate = non_empty},
                 <<"value">> => #option{type = binary}},
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
process_algorithm(Alg) -> maps:get(Alg, algorithms()).

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
    [#{kid => maps:get(kid, Key, undefined),
       algorithm => Alg,
       secret => read_secret(Secret)} || Key = #{algorithm := Alg, secret := Secret} <- Keys].

read_secret({value, Secret}) -> Secret;
read_secret({env, Var}) -> {env, Var};
read_secret({file, Path}) ->
    {ok, Secret} = file:read_file(Path),
    Secret.

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
    try jwerl:header(Token) of
        Header when is_map(Header) ->
            Kid = maps:get(kid, Header, undefined),
            verify_with_keys(Token, matching_keys(Kid, Keys));
        _ ->
            {error, invalid_token}
    catch _:_ ->
            {error, invalid_token}
    end.

matching_keys(Kid, Keys) when is_binary(Kid) ->
    [Key || Key = #{kid := KeyKid} <- Keys, KeyKid =:= Kid orelse KeyKid =:= undefined];
matching_keys(_, Keys) ->
    Keys.

verify_with_keys(_Token, []) ->
    {error, invalid_token};
verify_with_keys(Token, [#{algorithm := Alg, secret := Secret} | Keys]) ->
    case secret_value(Secret) of
        {ok, Key} ->
            try jwerl:verify(Token, Alg, Key) of
                {ok, Claims} when is_map(Claims) -> {ok, Claims};
                _ -> verify_with_keys(Token, Keys)
            catch _:_ ->
                    verify_with_keys(Token, Keys)
            end;
        error ->
            verify_with_keys(Token, Keys)
    end.

secret_value({env, Var}) ->
    case os:getenv(Var) of
        false -> error;
        Value -> {ok, list_to_binary(Value)}
    end;
secret_value(Secret) when is_binary(Secret) ->
    {ok, Secret}.

%% jwerl checks 'exp' only when it is present, but admin tokens must expire
check_claims(Claims, Opts) ->
    Checks = [{<<"exp">>, fun is_integer/1, missing_expiration}]
        ++ [{<<"iss">>, fun(Iss) -> Iss =:= Issuer end, wrong_issuer}
            || Issuer <- [maps:get(issuer, Opts, undefined)], Issuer =/= undefined]
        ++ [{<<"aud">>, fun(Aud) -> has_audience(Aud, Audience) end, wrong_audience}
            || Audience <- [maps:get(audience, Opts, undefined)], Audience =/= undefined],
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
%% jwerl decodes the claim names to atoms when such atoms exist.
-spec get_claim(binary(), claims()) -> term().
get_claim(Name, Claims) ->
    case maps:find(Name, Claims) of
        {ok, Value} ->
            Value;
        error ->
            try maps:get(binary_to_existing_atom(Name), Claims, undefined)
            catch error:badarg -> undefined
            end
    end.

%% Explicit mapping, because the atoms are owned by jwerl and might not exist yet
-spec algorithms() -> #{binary() => algorithm()}.
algorithms() ->
    #{<<"HS256">> => hs256, <<"RS256">> => rs256, <<"ES256">> => es256,
      <<"HS384">> => hs384, <<"RS384">> => rs384, <<"ES384">> => es384,
      <<"HS512">> => hs512, <<"RS512">> => rs512, <<"ES512">> => es512}.
