%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2014, 2600Hz INC
%%% @doc
%%% Detects if a call is fax
%%% user(s).
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%   Ben Wann
%%%   Luis Azedo
%%%-------------------------------------------------------------------
-module(cf_fax_detect).

-include("../callflow.hrl").

-export([handle/2]).

-define(DEFAULT_FAX_DETECT_DURATION, 5).
-define(FAX_DETECT_DURATION, whapps_config:get_integer(?CF_CONFIG_CAT, <<"fax_detect_duration_s">>, ?DEFAULT_FAX_DETECT_DURATION)).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Entry point for this module
%% @end
%%--------------------------------------------------------------------
-spec handle(wh_json:object(), whapps_call:call()) -> 'ok'.
handle(Data, Call) ->
    lager:info("detecting fax"),
    Duration = wh_json:get_integer_value(<<"duration">>, Data, ?FAX_DETECT_DURATION),
    case whapps_call_command:fax_detection(<<"inbound">>, Duration, Call) of
        'true' ->
            lager:debug("fax detected"),
            cf_exe:continue(<<"ON_FAX">>, Call);
        'false' ->
            lager:debug("fax not detected"),
            cf_exe:continue(<<"ON_VOICE">>, Call)
    end.
