%%%-------------------------------------------------------------------
%%% @copyright (C) 2012-2014, 2600Hz INC
%%% @doc
%%% Handlers for various call events, acdc events, etc
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(acdc_agent_handler).

%% Listener callbacks
-export([handle_status_update/2
         ,handle_sync_req/2
         ,handle_sync_resp/2
         ,handle_stats_req/2
         ,handle_call_event/2
         ,handle_new_channel/2
         ,handle_destroyed_channel/2
         ,handle_originate_resp/2
         ,handle_member_connect_win/2
         ,handle_member_message/2
         ,handle_agent_message/2
         ,handle_config_change/2
         ,handle_presence_probe/2
        ]).

-include("acdc.hrl").
-include_lib("whistle/include/wapi_conf.hrl").

-define(DEFAULT_PAUSE ,whapps_config:get(<<"acdc">>, <<"default_agent_pause_timeout">>, 600)).

-spec handle_status_update(wh_json:object(), wh_proplist()) -> 'ok'.
handle_status_update(JObj, _Props) ->
    _ = wh_util:put_callid(JObj),
    AccountId = wh_json:get_value(<<"Account-ID">>, JObj),
    AgentId = wh_json:get_value(<<"Agent-ID">>, JObj),

    lager:debug("status update recv for ~s (~s)", [AgentId, AccountId]),

    case wh_json:get_value(<<"Event-Name">>, JObj) of
        <<"login">> ->
            'true' = wapi_acdc_agent:login_v(JObj),
            login(AccountId, AgentId, JObj);
        <<"logout">> ->
            'true' = wapi_acdc_agent:logout_v(JObj),
            maybe_stop_agent(AccountId, AgentId, JObj);
        <<"pause">> ->
            'true' = wapi_acdc_agent:pause_v(JObj),

            Timeout = wh_json:get_integer_value(<<"Time-Limit">>, JObj, ?DEFAULT_PAUSE),
            Alias = wh_json:get_value(<<"Alias">>, JObj),

            maybe_pause_agent(AccountId, AgentId, Timeout, Alias, JObj);
        <<"resume">> ->
            'true' = wapi_acdc_agent:resume_v(JObj),
            maybe_resume_agent(AccountId, AgentId, JObj);
        Event -> maybe_agent_queue_change(AccountId, AgentId, Event
                                          ,wh_json:get_value(<<"Queue-ID">>, JObj)
                                          ,JObj
                                         )
    end.

-spec login(ne_binary(), ne_binary(), wh_json:object()) -> 'ok'.
login(AccountId, AgentId, JObj) ->
    case maybe_start_agent(AccountId, AgentId, JObj) of
        'fail' -> login_fail(JObj);
        _ -> login_success(JObj)
    end.

-spec maybe_agent_queue_change(ne_binary(), ne_binary(), ne_binary(), ne_binary(), wh_json:object()) -> 'ok'.
maybe_agent_queue_change(AccountId, AgentId, <<"login_queue">>, QueueId, JObj) ->
    lager:debug("queue login for agent ~s into ~s", [AgentId, QueueId]),
    case maybe_start_agent(AccountId, AgentId, JObj) of
        'fail' -> lager:error("could not start agent process for ~s", [AgentId]);
        Sup -> acdc_agent_fsm:add_acdc_queue(acdc_agent_sup:fsm(Sup), QueueId)
    end;
maybe_agent_queue_change(AccountId, AgentId, <<"logout_queue">>, QueueId, JObj) ->
    lager:debug("queue logout for agent ~s into ~s", [AgentId, QueueId]),
    case acdc_agents_sup:find_agent_supervisor(AccountId, AgentId) of
        'undefined' -> lager:debug("agent process for ~s already stopped");
        Sup ->
            maybe_update_presence(Sup, JObj),
            acdc_agent_fsm:rm_acdc_queue(acdc_agent_sup:fsm(Sup), QueueId)
    end.

-spec maybe_start_agent(ne_binary(), ne_binary(), wh_json:object()) -> pid() | 'fail'.
maybe_start_agent(AccountId, AgentId, JObj) ->
    try maybe_start_agent(AccountId, AgentId) of
        {'ok', Sup} ->
            timer:sleep(100),
            case erlang:is_process_alive(Sup) of
                'true' ->
                    maybe_update_presence(Sup, JObj),
                    acdc_agent_stats:agent_logged_in(AccountId, AgentId),
                    Sup;
                'false' ->
                    acdc_agent_stats:agent_logged_out(AccountId, AgentId),
                    'fail'
            end;
        {'exists', Sup} ->
            FSM = acdc_agent_sup:fsm(Sup),
            case presence_state(JObj, 'undefined') of
                'undefined' -> 'ok';
                PresenceState -> acdc_agent_fsm:update_presence(FSM, presence_id(JObj), PresenceState)
            end,
            Sup;
        {'error', _E} ->
            acdc_agent_stats:agent_logged_out(AccountId, AgentId),
            'fail'
    catch
        _E:_R ->
            acdc_agent_stats:agent_logged_out(AccountId, AgentId),
            'fail'
    end.

login_fail(JObj) ->
    login_resp(JObj, <<"failed">>).
login_success(JObj) ->
    login_resp(JObj, <<"success">>).

login_resp(JObj, Status) ->
    case {wh_json:get_value(<<"Server-ID">>, JObj), wh_json:get_value(<<"Msg-ID">>, JObj)} of
        {'undefined', _} -> lager:debug("not publishing a login resp: no server_id");
        {<<>>, _} -> lager:debug("not publishing a login resp: no server_id");
        {_, 'undefined'} -> lager:debug("not publishing a login resp: no msg_id");
        {ServerID, MsgId} ->
            Prop = [{<<"Status">>, Status}
                    ,{<<"Msg-ID">>, MsgId}
                    | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
                   ],
            wapi_acdc_agent:publish_login_resp(ServerID, Prop)
    end.

-spec maybe_start_agent(api_binary(), api_binary()) ->
                               {'ok', pid()} |
                               {'exists', pid()} |
                               {'error', any()}.
maybe_start_agent(AccountId, AgentId) ->
    case acdc_agents_sup:find_agent_supervisor(AccountId, AgentId) of
        'undefined' ->
            lager:debug("agent ~s (~s) not found, starting", [AgentId, AccountId]),
            case couch_mgr:open_doc(wh_util:format_account_id(AccountId, 'encoded'), AgentId) of
                {'ok', AgentJObj} -> acdc_agents_sup:new(AgentJObj);
                {'error', _E}=E ->
                    lager:debug("error opening agent doc: ~p", [_E]),
                    E
            end;
        Sup when is_pid(Sup) ->
            lager:debug("agent ~s (~s) already running: supervisor ~p", [AgentId, AccountId, Sup]),
            {'exists', Sup}
    end.

maybe_stop_agent(AccountId, AgentId, JObj) ->
    case acdc_agents_sup:find_agent_supervisor(AccountId, AgentId) of
        'undefined' ->
            lager:debug("agent ~s(~s) not found, nothing to do", [AgentId, AccountId]),
            catch acdc_util:presence_update(AccountId, presence_id(JObj, AgentId), ?PRESENCE_RED_SOLID),
            acdc_agent_stats:agent_logged_out(AccountId, AgentId);
        Sup when is_pid(Sup) ->
            lager:debug("agent ~s(~s) is logging out, stopping ~p", [AgentId, AgentId, Sup]),
            case catch acdc_agent_sup:fsm(Sup) of
                APid when is_pid(APid) ->
                    acdc_agent_fsm:update_presence(APid, presence_id(JObj), presence_state(JObj, ?PRESENCE_RED_SOLID)),
                    acdc_agent_fsm:agent_logout(APid);
                _P -> lager:debug("failed to find agent fsm for ~s: ~p", [AgentId, _P])
            end

    end.

maybe_pause_agent(AccountId, AgentId, Timeout, Alias, JObj) ->
    case acdc_agents_sup:find_agent_supervisor(AccountId, AgentId) of
        'undefined' -> lager:debug("agent ~s (~s) not found, nothing to do", [AgentId, AccountId]);
        Sup when is_pid(Sup) ->
            lager:debug("agent ~s(~s) is pausing (~p) for ~p", [AccountId, AgentId, Alias, Timeout]),
            FSM = acdc_agent_sup:fsm(Sup),
            acdc_agent_fsm:update_presence(FSM,  presence_id(JObj), presence_state(JObj, 'undefined')),
            acdc_agent_fsm:pause(FSM, Timeout, Alias)
    end.

maybe_resume_agent(AccountId, AgentId, JObj) ->
    case acdc_agents_sup:find_agent_supervisor(AccountId, AgentId) of
        'undefined' -> lager:debug("agent ~s (~s) not found, nothing to do", [AgentId, AccountId]);
        Sup when is_pid(Sup) ->
            lager:debug("agent ~s(~s) is resuming: ~p", [AccountId, AgentId, Sup]),
            FSM = acdc_agent_sup:fsm(Sup),
            acdc_agent_fsm:update_presence(FSM,  presence_id(JObj), presence_state(JObj, 'undefined')),
            acdc_agent_fsm:resume(FSM)
    end.

-spec handle_sync_req(wh_json:object(), wh_proplist()) -> 'ok'.
handle_sync_req(JObj, Props) ->
    'true' = wapi_acdc_agent:sync_req_v(JObj),
    acdc_agent_fsm:sync_req(props:get_value('fsm_pid', Props), JObj).

-spec handle_sync_resp(wh_json:object(), wh_proplist()) -> 'ok'.
handle_sync_resp(JObj, Props) ->
    'true' = wapi_acdc_agent:sync_resp_v(JObj),
    acdc_agent_fsm:sync_resp(props:get_value('fsm_pid', Props), JObj).

-spec handle_stats_req(wh_json:object(), wh_proplist()) -> 'ok'.
handle_stats_req(JObj, Props) ->
    'true' = wapi_acdc_agent:stats_req_v(JObj),

    AgentCallIds = lists:foldl(fun({CallId, _}, Acc) ->
        [CallId | Acc];
    (CallId, Acc) ->
        case binary:split(CallId, <<"-">>) of
            List when is_list(List) and length(List) =:= 3 ->
                [CallId | Acc];
            _ ->
                Acc
        end
    end, [], props:get_value('agent_call_ids', Props)),

    Prop = [{<<"Account-ID">>, props:get_value('acct_id', Props)}
            ,{<<"Agent-Call-IDs">>, AgentCallIds}
            ,{<<"Msg-ID">>, wh_json:get_value(<<"Msg-ID">>, JObj)}
            | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    Q = wh_json:get_value(<<"Server-ID">>, JObj),
    wapi_acdc_agent:publish_stats_resp(Q, Prop).

-spec handle_call_event(wh_json:object(), wh_proplist()) -> 'ok'.
handle_call_event(JObj, Props) ->
    _ = wh_util:put_callid(JObj),
    FSM = props:get_value('fsm_pid', Props),
    case wapi_call:event_v(JObj) of
        'true' ->
            {Category, Name} = wh_util:get_event_type(JObj),
            handle_call_event(Category, Name, FSM, JObj, Props);
        'false' ->
            'true' = wh_api:error_resp_v(JObj),

            case wh_json:get_value([<<"Request">>, <<"Event-Name">>], JObj) of
                <<"originate_req">> -> acdc_agent_fsm:originate_failed(FSM, JObj);
                _ -> 'ok'
            end
    end.

-spec handle_call_event(ne_binary(), ne_binary(), server_ref(), wh_json:object(), wh_proplist()) -> any().
handle_call_event(Category, <<"CHANNEL_DESTROY">> = Name, FSM, JObj, Props) ->
    Urls = props:get_value('cdr_urls', Props),
    CallId = wh_json:get_value(<<"Call-ID">>, JObj),
    case catch dict:fetch(CallId, Urls) of
        {'EXIT', _} -> lager:debug("no cdr url for call ~s", [CallId]);
        Url -> acdc_util:send_cdr(Url, JObj)
    end,
    Srv = props:get_value('server', Props),
    acdc_agent_fsm:call_event(FSM, Category, Name, JObj),
    _ = acdc_agent_listener:remove_cdr_urls(Srv, CallId),
    acdc_util:unbind_from_call_events(CallId, Srv);
handle_call_event(Category, Name, FSM, JObj, _) ->
    acdc_agent_fsm:call_event(FSM, Category, Name, JObj).

handle_new_channel(JObj, AccountId) ->
    'true' = wapi_call:event_v(JObj),
    _ = wh_util:put_callid(JObj),
    handle_new_channel_acct(JObj, AccountId).

-spec handle_new_channel_acct(wh_json:object(), api_binary()) -> 'ok'.
handle_new_channel_acct(_, 'undefined') -> 'ok';
handle_new_channel_acct(JObj, AccountId) ->
    FromUser = hd(binary:split(wh_json:get_value(<<"From">>, JObj), <<"@">>)),
    ToUser = hd(binary:split(wh_json:get_value(<<"To">>, JObj), <<"@">>)),
    ReqUser = hd(binary:split(wh_json:get_value(<<"Request">>, JObj), <<"@">>)),

    CallId = wh_json:get_value(<<"Call-ID">>, JObj),
    MemberCallId = wh_json:get_value([<<"Custom-Channel-Vars">>, <<"Member-Call-ID">>], JObj),

    lager:debug("new channel in acct ~s: from ~s to ~s(~s)", [AccountId, FromUser, ToUser, ReqUser]),

    case wh_json:get_value(<<"Call-Direction">>, JObj) of
        <<"inbound">> -> gproc:send(?NEW_CHANNEL_REG(AccountId, FromUser), ?NEW_CHANNEL_FROM(CallId));
        <<"outbound">> ->
            gproc:send(?NEW_CHANNEL_REG(AccountId, ToUser), ?NEW_CHANNEL_TO(CallId, MemberCallId)),
            gproc:send(?NEW_CHANNEL_REG(AccountId, ReqUser), ?NEW_CHANNEL_TO(CallId, MemberCallId));
        _ -> lager:debug("invalid call direction for call ~s", [CallId])
    end.

%%--------------------------------------------------------------------
%% @doc
%% Send event to agent FSM when channels are destroyed. This occurs in
%% addition to the above handle_call_event/2. Though this is redundant
%% in most cases, it will keep the agent from becoming stuck in the
%% outbound state if a channel is created and destroyed before the
%% acdc_agent_listener gen_listener can bind to it.
%%
%% @end
%%--------------------------------------------------------------------
-spec handle_destroyed_channel(wh_json:object(), api_binary()) -> 'ok'.
handle_destroyed_channel(JObj, AccountId) ->
    FromUser = hd(binary:split(wh_json:get_value(<<"From">>, JObj), <<"@">>)),
    ToUser = hd(binary:split(wh_json:get_value(<<"To">>, JObj), <<"@">>)),

    CallId = wh_json:get_value(<<"Call-ID">>, JObj),
    HangupCause = acdc_util:hangup_cause(JObj),

    lager:debug("destroyed channel in acct ~s: from ~s to ~s", [AccountId, FromUser, ToUser]),

    case kz_call_event:call_direction(JObj) of
        <<"inbound">> -> gproc:send(?DESTROYED_CHANNEL_REG(AccountId, FromUser)
                                    ,?DESTROYED_CHANNEL(CallId, HangupCause));
        <<"outbound">> ->
            gproc:send(?DESTROYED_CHANNEL_REG(AccountId, FromUser)
                       ,?DESTROYED_CHANNEL(CallId, HangupCause)),
            gproc:send(?DESTROYED_CHANNEL_REG(AccountId, ToUser)
                       ,?DESTROYED_CHANNEL(CallId, HangupCause));
        _ -> 'ok'
    end.

handle_originate_resp(JObj, Props) ->
    case wh_json:get_value(<<"Event-Name">>, JObj) of
        <<"originate_resp">> ->
            'true' = wapi_resource:originate_resp_v(JObj),
            acdc_agent_fsm:originate_resp(props:get_value('fsm_pid', Props), JObj);
        <<"originate_started">> ->
            'true' = wapi_resource:originate_started_v(JObj),
            acdc_agent_fsm:originate_started(props:get_value('fsm_pid', Props), JObj);
        <<"originate_uuid">> ->
            'true' = wapi_resource:originate_uuid_v(JObj),
            acdc_agent_fsm:originate_uuid(props:get_value('fsm_pid', Props), JObj)
    end.

-spec handle_member_connect_win(wh_json:object(), wh_proplist()) -> 'ok'.
handle_member_connect_win(JObj, Props) ->
    'true' = wapi_acdc_queue:member_connect_win_v(JObj),
    MyId = acdc_util:proc_id(props:get_value('fsm_pid', Props)),
    case wh_json:get_value(<<"Agent-Process-ID">>, JObj) of
        MyId -> acdc_agent_fsm:member_connect_win(props:get_value('fsm_pid', Props), JObj, 'same_node');
        _ -> acdc_agent_fsm:member_connect_win(props:get_value('fsm_pid', Props), JObj, 'different_node')
    end.

-spec handle_member_message(wh_json:object(), wh_proplist()) -> 'ok'.
-spec handle_member_message(wh_json:object(), wh_proplist(), ne_binary()) -> 'ok'.
handle_member_message(JObj, Props) ->
    handle_member_message(JObj, Props, wh_json:get_value(<<"Event-Name">>, JObj)).

handle_member_message(JObj, Props, <<"connect_req">>) ->
    'true' = wapi_acdc_queue:member_connect_req_v(JObj),
    acdc_agent_fsm:member_connect_req(props:get_value('fsm_pid', Props), JObj);
handle_member_message(_, _, EvtName) ->
    lager:debug("not handling member event ~s", [EvtName]).

-spec handle_agent_message(wh_json:object(), wh_proplist()) -> 'ok'.
-spec handle_agent_message(wh_json:object(), wh_proplist(), ne_binary()) -> 'ok'.
handle_agent_message(JObj, Props) ->
    handle_agent_message(JObj, Props, wh_json:get_value(<<"Event-Name">>, JObj)).

handle_agent_message(JObj, Props, <<"connect_timeout">>) ->
    'true' = wapi_acdc_queue:agent_timeout_v(JObj),
    acdc_agent_fsm:agent_timeout(props:get_value('fsm_pid', Props), JObj);
handle_agent_message(JObj, Props, <<"shared_failure">>) ->
    'true' = wapi_acdc_agent:shared_originate_failure_v(JObj),
    acdc_agent_fsm:shared_failure(props:get_value('fsm_pid', Props), JObj);
handle_agent_message(JObj, Props, <<"shared_call_id">>) ->
    'true' = wapi_acdc_agent:shared_call_id_v(JObj),
    acdc_agent_fsm:shared_call_id(props:get_value('fsm_pid', Props), JObj);
handle_agent_message(_, _, _EvtName) ->
    lager:debug("not handling agent event ~s", [_EvtName]).

handle_config_change(JObj, _Props) ->
    'true' = wapi_conf:doc_update_v(JObj),

    handle_change(JObj, wh_json:get_value(<<"Type">>, JObj)).

-spec handle_change(wh_json:object(), ne_binary()) -> 'ok'.
handle_change(JObj, <<"user">>) ->
    handle_agent_change(wh_json:get_value(<<"Database">>, JObj)
                        ,wh_json:get_value(<<"Account-ID">>, JObj)
                        ,wh_json:get_value(<<"ID">>, JObj)
                        ,wh_json:get_value(<<"Event-Name">>, JObj)
                       );
handle_change(JObj, <<"device">>) ->
    handle_device_change(wh_json:get_value(<<"Database">>, JObj)
                         ,wh_json:get_value(<<"Account-ID">>, JObj)
                         ,wh_json:get_value(<<"ID">>, JObj)
                         ,wh_json:get_value(<<"Rev">>, JObj)
                         ,wh_json:get_value(<<"Event-Name">>, JObj)
                        );
handle_change(JObj, <<"undefined">>) ->
    lager:debug("undefined type for change"),
    case couch_mgr:open_cache_doc(wh_json:get_value(<<"Database">>, JObj)
                                  ,wh_json:get_value(<<"ID">>, JObj)
                                 )
    of
        {'ok', Doc} ->
            Type = wh_doc:type(Doc),
            lager:debug("found doc of type ~s", [Type]),
            handle_change(JObj, Type);
        {'error', _E} ->
            lager:debug("failed to find doc")
    end.

handle_device_change(AccountDb, AccountId, DeviceId, Rev, Type) ->
    handle_device_change(AccountDb, AccountId, DeviceId, Rev, Type, 0).

handle_device_change(_AccountDb, _AccountId, DeviceId, Rev, _Type, Cnt) when Cnt > 3 ->
    lager:debug("retried ~p times to refresh endpoint ~s(~s), giving up", [Cnt, DeviceId, Rev]);
handle_device_change(AccountDb, AccountId, DeviceId, Rev, ?DOC_CREATED, Cnt) ->
    case cf_endpoint:get(DeviceId, AccountDb) of
        {'ok', EP} ->
            case wh_doc:revision(EP) of
                Rev ->
                    gproc:send(?ENDPOINT_UPDATE_REG(AccountId, DeviceId), ?ENDPOINT_CREATED(EP)),
                    gproc:send(?OWNER_UPDATE_REG(AccountId, wh_json:get_value(<<"owner_id">>, EP)), ?ENDPOINT_CREATED(EP));
                _OldRev ->
                    timer:sleep(250),
                    handle_device_change(AccountDb, AccountId, DeviceId, Rev, ?DOC_CREATED, Cnt+1)
            end;
        _ -> lager:debug("ignoring the fact that device ~s was created", [DeviceId])
    end;
handle_device_change(AccountDb, AccountId, DeviceId, Rev, ?DOC_EDITED, Cnt) ->
    case cf_endpoint:get(DeviceId, AccountDb) of
        {'ok', EP} ->
            case wh_doc:revision(EP) of
                Rev ->
                    gproc:send(?ENDPOINT_UPDATE_REG(AccountId, DeviceId), ?ENDPOINT_EDITED(EP)),
                    gproc:send(?OWNER_UPDATE_REG(AccountId, wh_json:get_value(<<"owner_id">>, EP)), ?ENDPOINT_EDITED(EP));
                _OldRev ->
                    timer:sleep(250),
                    handle_device_change(AccountDb, AccountId, DeviceId, Rev, ?DOC_EDITED, Cnt+1)
            end;
        _ -> lager:debug("ignoring the fact that device ~s was edited", [DeviceId])
    end;
handle_device_change(AccountDb, AccountId, DeviceId, Rev, ?DOC_DELETED, Cnt) ->
    case cf_endpoint:get(DeviceId, AccountDb) of
        {'ok', EP} ->
            case wh_doc:revision(EP) of
                Rev ->
                    gproc:send(?ENDPOINT_UPDATE_REG(AccountId, DeviceId), ?ENDPOINT_DELETED(EP)),
                    gproc:send(?OWNER_UPDATE_REG(AccountId, wh_json:get_value(<<"owner_id">>, EP)), ?ENDPOINT_DELETED(EP));
                _OldRev ->
                    timer:sleep(250),
                    handle_device_change(AccountDb, AccountId, DeviceId, Rev, ?DOC_DELETED, Cnt+1)
            end;
        _ -> lager:debug("ignoring the fact that device ~s was edited", [DeviceId])
    end.

handle_agent_change(_AccountDb, AccountId, AgentId, ?DOC_CREATED) ->
    lager:debug("new agent ~s(~s) created, hope they log in soon!", [AgentId, AccountId]);
handle_agent_change(AccountDb, AccountId, AgentId, ?DOC_EDITED) ->
    {'ok', JObj} = couch_mgr:open_doc(AccountDb, AgentId),
    lager:debug("agent ~s edited", [AgentId]),
    case acdc_agents_sup:find_agent_supervisor(AccountId, AgentId) of
        'undefined' -> lager:debug("failed to find agent ~s", [AgentId]);
        P when is_pid(P) -> acdc_agent_fsm:refresh(acdc_agent_sup:fsm(P), JObj)
    end;
handle_agent_change(_, AccountId, AgentId, ?DOC_DELETED) ->
    case acdc_agents_sup:find_agent_supervisor(AccountId, AgentId) of
        'undefined' -> lager:debug("user ~s has left us, but wasn't started", [AgentId]);
        P when is_pid(P) ->
            lager:debug("agent ~s(~s) has been deleted, stopping ~p", [AccountId, AgentId, P]),
            _ = acdc_agent_sup:stop(P),
            acdc_agent_stats:agent_logged_out(AccountId, AgentId)
    end.

handle_presence_probe(JObj, _Props) ->
    'true' = wapi_presence:probe_v(JObj),
    Realm = wh_json:get_value(<<"Realm">>, JObj),
    case whapps_util:get_account_by_realm(Realm) of
        {'ok', AcctDb} -> maybe_respond_to_presence_probe(JObj, wh_util:format_account_id(AcctDb, 'raw'));
        _ -> lager:debug("ignoring presence probe from realm ~s", [Realm])
    end.

maybe_respond_to_presence_probe(JObj, AccountId) ->
    case wh_json:get_value(<<"Username">>, JObj) of
        'undefined' -> lager:debug("no user on presence probe for ~s", [AccountId]);
        AgentId ->
            update_probe(JObj, acdc_agents_sup:find_agent_supervisor(AccountId, AgentId))
    end.

update_probe(_JObj, 'undefined') -> 'ok';
update_probe(JObj, P) when is_pid(P) ->
    lager:debug("agent is active with supervisor: ~p", [P]),
    send_probe(JObj, ?PRESENCE_GREEN).

send_probe(JObj, State) ->
    To = <<(wh_json:get_value(<<"Username">>, JObj))/binary
           ,"@"
           ,(wh_json:get_value(<<"Realm">>, JObj))/binary>>,
    PresenceUpdate =
        [{<<"State">>, State}
         ,{<<"Presence-ID">>, To}
         ,{<<"Call-ID">>, wh_util:to_hex_binary(crypto:hash(md5, To))}
         | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
        ],
    wapi_presence:publish_update(PresenceUpdate).

presence_id(JObj) ->
    presence_id(JObj, 'undefined').
presence_id(JObj, AgentId) ->
    lager:debug("find presence in ~p", [JObj]),
    wh_json:get_value(<<"Presence-ID">>, JObj, AgentId).

-spec presence_state(wh_json:object(), api_binary()) -> api_binary().
presence_state(JObj, State) ->
    wh_json:get_value(<<"Presence-State">>, JObj, State).

maybe_update_presence(Sup, JObj) ->
    maybe_update_presence(Sup, JObj, 'undefined').
maybe_update_presence(Sup, JObj, PresenceState) ->
    APid = acdc_agent_sup:listener(Sup),
    acdc_agent_listener:maybe_update_presence_id(APid, presence_id(JObj)),
    acdc_agent_listener:presence_update(APid, presence_state(JObj, PresenceState)).
