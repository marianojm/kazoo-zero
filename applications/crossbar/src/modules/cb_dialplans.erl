%%%-------------------------------------------------------------------
%%% @copyright (C) 2015, 2600Hz INC
%%% @doc
%%%
%%% @end
%%% @contributors:
%%%   Karl Anderson
%%%   James Aimonetti
%%%   Sponsored by Conversant Ltd,
%%%     implemented by SIPLABS, LLC (Ilya Ashchepkov)
%%%-------------------------------------------------------------------
-module(cb_dialplans).

-export([init/0
         ,allowed_methods/0
         ,resource_exists/0
         ,validate/1
        ]).

-include("../crossbar.hrl").

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Initializes the bindings this module will respond to.
%% @end
%%--------------------------------------------------------------------
-spec init() -> 'ok'.
init() ->
    _ = crossbar_bindings:bind(<<"*.allowed_methods.dialplans">>, ?MODULE, 'allowed_methods'),
    _ = crossbar_bindings:bind(<<"*.resource_exists.dialplans">>, ?MODULE, 'resource_exists'),
    _ = crossbar_bindings:bind(<<"*.validate.dialplans">>, ?MODULE, 'validate').

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Given the path tokens related to this module, what HTTP methods are
%% going to be responded to.
%% @end
%%--------------------------------------------------------------------
-spec allowed_methods() -> http_methods().
allowed_methods() ->
    [?HTTP_GET].

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec resource_exists() -> 'true'.
resource_exists() -> 'true'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec validate(cb_context:context()) -> cb_context:context().
validate(Context) ->
    Doc = maybe_add_name(whapps_config:get_all_kvs(<<"dialplans">>)),
    cb_context:setters(Context, [{fun cb_context:set_resp_data/2, Doc}
                                 ,{fun cb_context:set_resp_status/2, 'success'}
                                ]).

-spec maybe_add_name(wh_proplist()) -> wh_json:object().
maybe_add_name(KVs) ->
    maybe_add_name(KVs, wh_json:new()).

-spec maybe_add_name(wh_proplist(), wh_json:object()) -> wh_json:object().
maybe_add_name([], Acc) -> Acc;
maybe_add_name([{K, V} | KVs], Acc0) ->
    Acc = case wh_json:get_ne_binary_value(<<"name">>, V) of
              'undefined' ->
                  JObj = wh_json:set_value(<<"name">>, K, V),
                  wh_json:set_value(K, JObj, Acc0);
              _Other ->
                  wh_json:set_value(K, V, Acc0)
          end,
    maybe_add_name(KVs, Acc).
