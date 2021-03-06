%%%-------------------------------------------------------------------
%%% @copyright (C) 2012-2015, 2600Hz
%%% @doc
%%% Manages queue processes:
%%%   starting when a queue is created
%%%   stopping when a queue is deleted
%%%   collecting stats from queues
%%%   and more!!!
%%% @end
%%% @contributors
%%%   KAZOO-3596: Sponsored by GTNetwork LLC, implemented by SIPLABS LLC
%%%   Daniel Finke
%%%-------------------------------------------------------------------
-module(acdc_queue_manager).

-behaviour(gen_listener).

%% API
-export([start_link/2, start_link/3
         ,handle_member_call/2
         ,handle_member_call_cancel/2
         ,handle_agent_change/2
         ,handle_agents_available_req/2
         ,handle_queue_member_add/2
         ,handle_queue_member_remove/2
         ,handle_queue_member_position/2
         ,handle_manager_success_notify/2
         ,handle_member_callback_reg/2
         ,are_agents_available/1
         ,handle_config_change/2
         ,should_ignore_member_call/3, should_ignore_member_call/4
         ,up_next/2
         ,config/1
         ,status/1
         ,current_agents/1
         ,refresh/2
         ,callback_details/2
        ]).

%% FSM helpers
-export([pick_winner/2]).

%% gen_server callbacks
-export([init/1
         ,handle_call/3
         ,handle_cast/2
         ,handle_info/2
         ,handle_event/2
         ,terminate/2
         ,code_change/3
        ]).

-export([announce_position_loop/7]).

-include("acdc.hrl").
-include("acdc_queue_manager.hrl").

-define(SERVER, ?MODULE).

-ifdef(TEST).
-compile('export_all').
-endif.

-define(BINDINGS(A, Q), [{'conf', [{'type', <<"queue">>}
                                   ,{'db', wh_util:format_account_id(A, 'encoded')}
                                   ,{'id', Q}
                                   ,'federate'
                                  ]}
                         ,{'acdc_queue', [{'restrict_to', ['member_call_result', 'stats_req', 'agent_change', 'agents_availability'
                                                           ,'member_addremove', 'member_position', 'member_callback_reg']}
                                          ,{'account_id', A}
                                          ,{'queue_id', Q}
                                         ]}
                         ,{'presence', [{'restrict_to', ['probe']}]}
                         ,{'acdc_stats', [{'restrict_to', ['status_stat']}
                                          ,{'account_id', A}
                                         ]}
                        ]).
-define(AGENT_BINDINGS(AccountId, AgentId), [
                                            ]).

-define(RESPONDERS, [{{'acdc_queue_handler', 'handle_config_change'}
                      ,[{<<"configuration">>, <<"*">>}]
                     }
                     ,{{'acdc_queue_handler', 'handle_stats_req'}
                       ,[{<<"queue">>, <<"stats_req">>}]
                      }
                     ,{{'acdc_queue_handler', 'handle_presence_probe'}
                       ,[{<<"presence">>, <<"probe">>}]
                      }
                     ,{{'acdc_queue_manager', 'handle_member_call'}
                       ,[{<<"member">>, <<"call">>}]
                      }
                     ,{{'acdc_queue_manager', 'handle_member_call_cancel'}
                       ,[{<<"member">>, <<"call_cancel">>}]
                      }
                     ,{{'acdc_queue_manager', 'handle_agent_change'}
                       ,[{<<"queue">>, <<"agent_change">>}]
                      }
                     ,{{'acdc_queue_manager', 'handle_agents_available_req'}
                       ,[{<<"queue">>, <<"agents_available_req">>}]
                      }
                     ,{{'acdc_queue_manager', 'handle_queue_member_add'}
                       ,[{<<"queue">>, <<"member_add">>}]
                      }
                     ,{{'acdc_queue_manager', 'handle_queue_member_remove'}
                       ,[{<<"queue">>, <<"member_remove">>}]
                      }
                     ,{{'acdc_queue_manager', 'handle_queue_member_position'}
                       ,[{<<"queue">>, <<"call_position_req">>}]
                      }
                     ,{{'acdc_queue_manager', 'handle_manager_success_notify'}
                       ,[{<<"member">>, <<"call_success">>}]
                      }
                     ,{{'acdc_queue_manager', 'handle_member_callback_reg'}
                       ,[{<<"member">>, <<"callback_reg">>}]
                      }
                    ]).

-define(SECONDARY_BINDINGS(AccountId, QueueId)
        ,[{'acdc_queue', [{'restrict_to', ['member_call']}
                          ,{'account_id', AccountId}
                          ,{'queue_id', QueueId}
                         ]}
         ]).
-define(SECONDARY_QUEUE_NAME(QueueId), <<"acdc.queue.manager.", QueueId/binary>>).
-define(SECONDARY_QUEUE_OPTIONS(MaxPriority), [{'exclusive', 'false'}
                                               ,{'arguments',[{<<"x-max-priority">>, MaxPriority}]}
                                              ]).
-define(SECONDARY_CONSUME_OPTIONS, [{'exclusive', 'false'}]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
-spec start_link(pid(), wh_json:object()) -> startlink_ret().
start_link(Super, QueueJObj) ->
    AccountId = wh_doc:account_id(QueueJObj),
    QueueId = wh_doc:id(QueueJObj),

    gen_listener:start_link(?MODULE
                            ,[{'bindings', ?BINDINGS(AccountId, QueueId)}
                              ,{'responders', ?RESPONDERS}
                             ]
                            ,[Super, QueueJObj]
                           ).

-spec start_link(pid(), ne_binary(), ne_binary()) -> startlink_ret().
start_link(Super, AccountId, QueueId) ->
    gen_listener:start_link(?MODULE
                            ,[{'bindings', ?BINDINGS(AccountId, QueueId)}
                              ,{'responders', ?RESPONDERS}
                             ]
                            ,[Super, AccountId, QueueId]
                           ).

handle_member_call(JObj, Props) ->
    'true' = wapi_acdc_queue:member_call_v(JObj),
    _ = wh_util:put_callid(JObj),

    Call = whapps_call:from_json(wh_json:get_value(<<"Call">>, JObj)),

    case are_agents_available(props:get_value('server', Props)
                              ,props:get_value('enter_when_empty', Props)
                             )
    of
        'false' ->
            lager:info("no agents are available to take the call, cancel queueing"),
            gen_listener:cast(props:get_value('server', Props)
                              ,{'reject_member_call', Call, JObj}
                             );
        'true' ->
            start_queue_call(JObj, Props, Call)
    end.

-spec are_agents_available(server_ref()) -> boolean().
are_agents_available(Srv) ->
    are_agents_available(Srv, gen_listener:call(Srv, 'enter_when_empty')).

are_agents_available(Srv, EnterWhenEmpty) ->
    agents_available(Srv) > 0 orelse EnterWhenEmpty.

start_queue_call(JObj, Props, Call) ->
    _ = whapps_call:put_callid(Call),
    QueueId = wh_json:get_value(<<"Queue-ID">>, JObj),

    lager:info("member call for queue ~s recv", [QueueId]),
    lager:debug("answering call"),
    whapps_call_command:answer_now(Call),

    case wh_media_util:media_path(props:get_value('moh', Props), Call) of
        'undefined' ->
            lager:debug("using default moh"),
            whapps_call_command:hold(Call);
        MOH ->
            lager:debug("using MOH ~s (~p)", [MOH, Props]),
            whapps_call_command:hold(MOH, Call)
    end,

    JObj2 = wh_json:set_value([<<"Call">>, <<"Custom-Channel-Vars">>, <<"Queue-ID">>], QueueId, JObj),

    _ = whapps_call_command:set('undefined'
                                ,wh_json:from_list([{<<"Eavesdrop-Group-ID">>, QueueId}
                                                    ,{<<"Queue-ID">>, QueueId}
                                                   ])
                                ,Call
                               ),

    %% Add member to queue for tracking position
    gen_listener:cast(props:get_value('server', Props), {'add_queue_member', JObj2}).

handle_member_call_cancel(JObj, Props) ->
    wh_util:put_callid(JObj),
    lager:debug("cancel call ~p", [JObj]),
    'true' = wapi_acdc_queue:member_call_cancel_v(JObj),
    K = make_ignore_key(wh_json:get_value(<<"Account-ID">>, JObj)
                        ,wh_json:get_value(<<"Queue-ID">>, JObj)
                        ,wh_json:get_value(<<"Call-ID">>, JObj)
                       ),

    gen_listener:cast(props:get_value('server', Props), {'member_call_cancel', K, JObj}).

handle_agent_change(JObj, Prop) ->
    'true' = wapi_acdc_queue:agent_change_v(JObj),
    Server = props:get_value('server', Prop),
    case wh_json:get_value(<<"Change">>, JObj) of
        <<"available">> ->
            gen_listener:cast(Server, {'agent_available', JObj});
        <<"ringing">> ->
            gen_listener:cast(Server, {'agent_ringing', JObj});
        <<"busy">> ->
            gen_listener:cast(Server, {'agent_busy', JObj});
        <<"unavailable">> ->
            gen_listener:cast(Server, {'agent_unavailable', JObj})
    end.

-spec handle_agents_available_req(wh_json:object(), wh_proplist()) -> 'ok'.
handle_agents_available_req(JObj, Prop) ->
    gen_listener:cast(props:get_value('server', Prop), {'agents_available_req', JObj}).

-spec handle_queue_member_add(wh_json:object(), wh_proplist()) -> 'ok'.
handle_queue_member_add(JObj, Prop) ->
    gen_listener:cast(props:get_value('server', Prop), {'handle_queue_member_add', JObj, props:get_value('queue', Prop)}).

-spec handle_queue_member_remove(wh_json:object(), wh_proplist()) -> 'ok'.
handle_queue_member_remove(JObj, Prop) ->
    gen_listener:cast(props:get_value('server', Prop), {'handle_queue_member_remove', wh_json:get_value(<<"JObj">>, JObj)}).

-spec handle_queue_member_position(wh_json:object(), wh_proplist()) -> 'ok'.
handle_queue_member_position(JObj, Prop) ->
	gen_listener:cast(props:get_value('server', Prop), {'queue_member_position', JObj}).

-spec handle_manager_success_notify(wh_json:object(), wh_proplist()) -> 'ok'.
handle_manager_success_notify(JObj, Prop) ->
    gen_listener:cast(props:get_value('server', Prop), {'handle_queue_member_remove', JObj}).

-spec handle_member_callback_reg(wh_json:object(), wh_proplist()) -> 'ok'.
handle_member_callback_reg(JObj, Prop) ->
    gen_listener:cast(props:get_value('server', Prop), {'handle_member_callback_reg', JObj}).

-spec handle_config_change(server_ref(), wh_json:object()) -> 'ok'.
handle_config_change(Srv, JObj) ->
    gen_listener:cast(Srv, {'update_queue_config', JObj}).

-spec should_ignore_member_call(server_ref(), whapps_call:call(), wh_json:object()) -> boolean().
-spec should_ignore_member_call(server_ref(), whapps_call:call(), ne_binary(), ne_binary()) -> boolean().
should_ignore_member_call(Srv, Call, CallJObj) ->
    should_ignore_member_call(Srv
                              ,Call
                              ,wh_json:get_value(<<"Account-ID">>, CallJObj)
                              ,wh_json:get_value(<<"Queue-ID">>, CallJObj)
                             ).
should_ignore_member_call(Srv, Call, AccountId, QueueId) ->
    K = make_ignore_key(AccountId, QueueId, whapps_call:call_id(Call)),
    gen_listener:call(Srv, {'should_ignore_member_call', K}).

-spec up_next(pid(), ne_binary()) -> boolean().
up_next(Srv, CallId) ->
    gen_listener:call(Srv, {'up_next', CallId}).

-spec config(pid()) -> {ne_binary(), ne_binary()}.
config(Srv) -> gen_listener:call(Srv, 'config').

-spec current_agents(server_ref()) -> ne_binaries().
current_agents(Srv) -> gen_listener:call(Srv, 'current_agents').

status(Srv) -> gen_listener:call(Srv, 'status').

refresh(Mgr, QueueJObj) -> gen_listener:cast(Mgr, {'refresh', QueueJObj}).

strategy(Srv) -> gen_listener:call(Srv, 'strategy').
next_winner(Srv) -> gen_listener:call(Srv, 'next_winner').

agents_available(Srv) -> gen_listener:call(Srv, 'agents_available').

pick_winner(Srv, Resps) -> pick_winner(Srv, Resps, strategy(Srv), next_winner(Srv)).

-spec callback_details(pid(), ne_binary()) -> api_binary().
callback_details(Srv, CallId) ->
    gen_listener:call(Srv, {'callback_details', CallId}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Super, QueueJObj]) ->
    AccountId = wh_doc:account_id(QueueJObj),
    QueueId = wh_doc:id(QueueJObj),

    wh_util:put_callid(<<"mgr_", QueueId/binary>>),

    init(Super, AccountId, QueueId, QueueJObj);

init([Super, AccountId, QueueId]) ->
    wh_util:put_callid(<<"mgr_", QueueId/binary>>),

    AcctDb = wh_util:format_account_id(AccountId, 'encoded'),
    {'ok', QueueJObj} = couch_mgr:open_cache_doc(AcctDb, QueueId),

    init(Super, AccountId, QueueId, QueueJObj).

init(Super, AccountId, QueueId, QueueJObj) ->
    process_flag('trap_exit', 'false'),

    AccountDb = wh_util:format_account_id(AccountId, 'encoded'),
    couch_mgr:add_to_doc_cache(AccountDb, QueueId, QueueJObj),

    _ = start_secondary_queue(AccountId, QueueId),

    gen_listener:cast(self(), {'start_workers'}),
    Strategy = get_strategy(wh_json:get_value(<<"strategy">>, QueueJObj)),
    StrategyState = create_strategy_state(Strategy, AccountDb, QueueId),

    _ = update_strategy_state(self(), Strategy, StrategyState),

    lager:debug("queue mgr started for ~s", [QueueId]),
    {'ok', update_properties(QueueJObj, #state{account_id=AccountId
                                               ,queue_id=QueueId
                                               ,supervisor=Super
                                               ,strategy=Strategy
                                               ,strategy_state=StrategyState
                                              })}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {'reply', Reply, State} |
%%                                   {'reply', Reply, State, Timeout} |
%%                                   {'noreply', State} |
%%                                   {'noreply', State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({'should_ignore_member_call', {AccountId, QueueId, CallId}=K}, _, #state{ignored_member_calls=Dict
                                                                                    ,account_id=AccountId
                                                                                    ,queue_id=QueueId
                                                                                   }=State) ->
    case catch dict:fetch(K, Dict) of
        {'EXIT', _} -> {'reply', 'false', State};
        _Res ->
            publish_queue_member_remove(AccountId, QueueId
                                        ,wh_json:set_value(<<"Call-ID">>, CallId, wh_json:new())),
            {'reply', 'true', State#state{ignored_member_calls=dict:erase(K, Dict)}}
    end;

handle_call({'up_next', CallId}, _, #state{strategy_state=SS
                                           ,current_member_calls=CurrentCalls
                                          }=State) ->
    Available = ss_size(SS, 'free'),
    Reply = up_next_fold(lists:reverse(CurrentCalls), CallId, Available),
    {'reply', Reply, State};

handle_call('config', _, #state{account_id=AccountId
                                ,queue_id=QueueId
                               }=State) ->
    {'reply', {AccountId, QueueId}, State};

handle_call('status', _, #state{strategy_state=#strategy_state{details=Details}}=State) ->
    Known = [A || {A, {N, _}} <- dict:to_list(Details), N > 0],
    {'reply', Known, State};

handle_call('strategy', _, #state{strategy=Strategy}=State) ->
    {'reply', Strategy, State, 'hibernate'};

handle_call('agents_available', _, #state{strategy_state=SS}=State) ->
    {'reply', ss_size(SS, 'logged_in'), State};

handle_call('enter_when_empty', _, #state{enter_when_empty=EnterWhenEmpty}=State) ->
    {'reply', EnterWhenEmpty, State};

handle_call('next_winner', _, #state{strategy='mi'}=State) ->
    {'reply', 'undefined', State};
handle_call('next_winner', _, #state{strategy='rr'
                                     ,strategy_state=#strategy_state{agents=Agents}=SS
                                    }=State) ->
    case queue:out(Agents) of
        {{'value', Winner}, Agents1} ->
            {'reply', Winner, State#state{strategy_state=SS#strategy_state{agents=queue:in(Winner, Agents1)}}, 'hibernate'};
        {'empty', _} ->
            {'reply', 'undefined', State}
    end;

handle_call('current_agents', _, #state{strategy='rr'
                                        ,strategy_state=#strategy_state{agents=Q}
                                       }=State) ->
    {'reply', queue:to_list(Q), State};
handle_call('current_agents', _, #state{strategy='mi'
                                        ,strategy_state=#strategy_state{agents=L}
                                       }=State) ->
    {'reply', L, State};

handle_call({'queue_position', CallId}, _, #state{current_member_calls=CurrentCalls
                                                 }=State) ->
    Call = lists:keyfind(CallId, 2, CurrentCalls),

    {Map, _} = lists:mapfoldr(fun(X, I) -> {{X, I}, I + 1} end, 1, CurrentCalls),
    Index = case lists:keyfind(Call, 1, Map) of
        {_, Index2} ->
            Index2;
        _Result ->
            lager:debug("call id ~p", [CallId]),
            lists:foreach(fun(Call2) ->
                lager:debug("current call id ~p", [whapps_call:call_id(Call2)])
            end, CurrentCalls),
            'true' = wh_json:get_value(<<"Stop">>, wh_json:new())
    end,

    {'reply', Index, State};

handle_call({'callback_details', CallId}, _, #state{registered_callbacks=Callbacks}=State) ->
    {'reply', props:get_value(CallId, Callbacks), State};

handle_call(_Request, _From, State) ->
    {'reply', 'ok', State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {'noreply', State} |
%%                                  {'noreply', State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({'update_strategy', StrategyState}, State) ->
    {'noreply', State#state{strategy_state=StrategyState}, 'hibernate'};

handle_cast({'update_queue_config', JObj}, #state{enter_when_empty=_EnterWhenEmpty}=State) ->
    EWE = wh_json:is_true([<<"Doc">>, <<"enter_when_empty">>], JObj, 'true'),
    lager:debug("maybe changing ewe from ~s to ~s", [_EnterWhenEmpty, EWE]),
    {'noreply', State#state{enter_when_empty=EWE}, 'hibernate'};

handle_cast({'member_call_cancel', K, JObj}, #state{ignored_member_calls=Dict}=State) ->
    AccountId = wh_json:get_value(<<"Account-ID">>, JObj),
    QueueId = wh_json:get_value(<<"Queue-ID">>, JObj),
    CallId = wh_json:get_value(<<"Call-ID">>, JObj),
    Reason = wh_json:get_value(<<"Reason">>, JObj),

    acdc_stats:call_abandoned(AccountId, QueueId, CallId, Reason),
    case Reason of
        %% Don't add to ignored_member_calls because an FSM has already dealt with this call
        <<"No agents left in queue">> ->
            {'noreply', State};
        _ ->
            {'noreply', State#state{ignored_member_calls=dict:store(K, 'true', Dict)}}
    end;

handle_cast({'monitor_call', Call}, State) ->
    CallId = whapps_call:call_id(Call),
    gen_listener:add_binding(self(), 'call', [{'callid', CallId}
                                              ,{'restrict_to', [<<"CHANNEL_DESTROY">>]}
                                             ]),
    lager:debug("bound for call events for ~s", [CallId]),
    {'noreply', State};
handle_cast({'start_workers'}, #state{account_id=AccountId
                                      ,queue_id=QueueId
                                      ,supervisor=QueueSup
                                     }=State) ->
    WorkersSup = acdc_queue_sup:workers_sup(QueueSup),
    case couch_mgr:get_results(wh_util:format_account_id(AccountId, 'encoded')
                               ,<<"queues/agents_listing">>
                               ,[{'key', QueueId}
                                 ,'include_docs'
                                ])
    of
        {'ok', []} ->
            lager:debug("no agents yet, but create a worker anyway"),
            acdc_queue_workers_sup:new_worker(WorkersSup, AccountId, QueueId);
        {'ok', Agents} ->
            _ = [start_agent_and_worker(WorkersSup, AccountId, QueueId
                                        ,wh_json:get_value(<<"doc">>, A)
                                       )
                 || A <- Agents
                ],
            'ok';
        {'error', _E} ->
            lager:debug("failed to find agent count: ~p", [_E]),
            QWC = whapps_config:get_integer(<<"acdc">>, <<"queue_worker_count">>, 5),
            acdc_queue_workers_sup:new_workers(WorkersSup, AccountId, QueueId, QWC)
    end,
    {'noreply', State};

handle_cast({'start_worker'}, State) ->
    handle_cast({'start_worker', 1}, State);
handle_cast({'start_worker', N}, #state{account_id=AccountId
                                        ,queue_id=QueueId
                                        ,supervisor=QueueSup
                                       }=State) ->
    WorkersSup = acdc_queue_sup:workers_sup(QueueSup),
    acdc_queue_workers_sup:new_workers(WorkersSup, AccountId, QueueId, N),
    {'noreply', State};

handle_cast({'agent_available', AgentId}, #state{strategy=Strategy
                                                 ,strategy_state=StrategyState
                                                 ,supervisor=QueueSup
                                                }=State) when is_binary(AgentId) ->
    lager:info("adding agent ~s to strategy ~s", [AgentId, Strategy]),
    StrategyState1 = update_strategy_with_agent(Strategy, StrategyState, AgentId, 'add', 'undefined'),
    maybe_start_queue_workers(QueueSup, ss_size(StrategyState1, 'logged_in')),
    {'noreply', State#state{strategy_state=StrategyState1}
     ,'hibernate'};
handle_cast({'agent_available', JObj}, State) ->
    handle_cast({'agent_available', wh_json:get_value(<<"Agent-ID">>, JObj)}, State);

handle_cast({'agent_ringing', AgentId}, #state{strategy=Strategy
                                               ,strategy_state=StrategyState
                                              }=State) when is_binary(AgentId) ->
    lager:info("agent ~s ringing, maybe updating strategy ~s", [AgentId, Strategy]),

    StrategyState1 = maybe_update_strategy(Strategy, StrategyState, AgentId),
    {'noreply', State#state{strategy_state=StrategyState1}, 'hibernate'};
handle_cast({'agent_ringing', JObj}, State) ->
    handle_cast({'agent_ringing', wh_json:get_value(<<"Agent-ID">>, JObj)}, State);

handle_cast({'agent_busy', AgentId}, #state{strategy=Strategy
                                            ,strategy_state=StrategyState
                                           }=State) when is_binary(AgentId) ->
    lager:info("agent ~s busy, maybe updating strategy ~s", [AgentId, Strategy]),

    StrategyState1 = update_strategy_with_agent(Strategy, StrategyState, AgentId, 'remove', 'busy'),
    {'noreply', State#state{strategy_state=StrategyState1}
     ,'hibernate'};
handle_cast({'agent_busy', JObj}, State) ->
    handle_cast({'agent_busy', wh_json:get_value(<<"Agent-ID">>, JObj)}, State);

handle_cast({'agent_unavailable', AgentId}, #state{strategy=Strategy
                                                   ,strategy_state=StrategyState
                                                  }=State) when is_binary(AgentId) ->
    lager:info("agent ~s unavailable, maybe updating strategy ~s", [AgentId, Strategy]),

    StrategyState1 = update_strategy_with_agent(Strategy, StrategyState, AgentId, 'remove', 'undefined'),
    {'noreply', State#state{strategy_state=StrategyState1}
     ,'hibernate'};
handle_cast({'agent_unavailable', JObj}, State) ->
    handle_cast({'agent_unavailable', wh_json:get_value(<<"Agent-ID">>, JObj)}, State);

handle_cast({'agents_available_req', JObj}, #state{account_id=AccountId
                                                   ,queue_id=QueueId
                                                   ,strategy_state=StrategyState
                                                  }=State) ->
    Resp = [{<<"Account-ID">>, AccountId}
            ,{<<"Queue-ID">>, QueueId}
            ,{<<"Agent-Count">>, ss_size(StrategyState, 'logged_in')}
            ,{<<"Msg-ID">>, wh_json:get_value(<<"Msg-ID">>, JObj)}
            | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    Q = wh_json:get_value(<<"Server-ID">>, JObj),
    wapi_acdc_queue:publish_agents_available_resp(Q, Resp),
    {'noreply', State};

handle_cast({'reject_member_call', Call, JObj}, #state{account_id=AccountId
                                                       ,queue_id=QueueId
                                                      }=State) ->
    Prop = [{<<"Call-ID">>, whapps_call:call_id(Call)}
            ,{<<"Account-ID">>, AccountId}
            ,{<<"Queue-ID">>, QueueId}
            ,{<<"Failure-Reason">>, <<"no agents">>}
            | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    Q = wh_json:get_value(<<"Server-ID">>, JObj),
    catch wapi_acdc_queue:publish_member_call_failure(Q, Prop),
    {'noreply', State};

handle_cast({'sync_with_agent', A}, #state{account_id=AccountId}=State) ->
    case acdc_agent_util:most_recent_status(AccountId, A) of
        {'ok', <<"logged_out">>} -> gen_listener:cast(self(), {'agent_unavailable', A});
        _ -> gen_listener:cast(self(), {'agent_available', A})
    end,
    {'noreply', State};

handle_cast({'gen_listener', {'created_queue', _}}, State) ->
    {'noreply', State};

handle_cast({'refresh', QueueJObj}, State) ->
    lager:debug("refreshing queue configs"),
    {'noreply', update_properties(QueueJObj, State), 'hibernate'};

handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, State) ->
    {'noreply', State};

handle_cast({'add_queue_member', JObj}, #state{account_id=AccountId
                                               ,queue_id=QueueId
                                               ,pos_announce_enabled=PosAnnounceEnabled
                                               ,wait_announce_enabled=WaitAnnounceEnabled
                                               ,announcements_timer=AnnouncementsTimer
                                               ,current_member_calls=CurrentCalls
                                               ,pos_announce_pids=Pids
                                              }=State) ->
    Position = length(CurrentCalls)+1,
    Call = whapps_call:set_custom_channel_var(<<"Queue-Position">>, Position
                                              ,whapps_call:from_json(wh_json:get_value(<<"Call">>, JObj))),

    {CIDNumber, CIDName} = acdc_util:caller_id(Call),
    acdc_stats:call_waiting(AccountId, QueueId, Position
                            ,whapps_call:call_id(Call)
                            ,CIDName
                            ,CIDNumber
                            ,wh_json:get_integer_value(<<"Member-Priority">>, JObj)
                           ),

    publish_queue_member_add(AccountId, QueueId, JObj),

    %% Add call to shared queue
    wapi_acdc_queue:publish_shared_member_call(AccountId, QueueId, JObj),
    lager:debug("put call into shared messaging queue"),

    gen_listener:cast(self(), {'monitor_call', Call}),

    acdc_util:presence_update(AccountId, QueueId, ?PRESENCE_RED_FLASH),

    %% Schedule position announcements
    UpdatedAnnouncePids = maybe_schedule_position_announcements(
                            Call
                            ,QueueId
                            ,{PosAnnounceEnabled, WaitAnnounceEnabled}
                            ,AnnouncementsTimer
                            ,queue_media_list(State)
                            ,Pids),

    {'noreply', State#state{current_member_calls=[Call | CurrentCalls]
                            ,pos_announce_pids=UpdatedAnnouncePids
                           }};

handle_cast({'handle_queue_member_add', JObj, _Queue}, #state{current_member_calls=CurrentCalls}=State) ->
    JObj2 = wh_json:get_value(<<"JObj">>, JObj),
    Call = whapps_call:from_json(wh_json:get_value(<<"Call">>, JObj2)),
    CallId = whapps_call:call_id(Call),
    lager:debug("received notification of new queue member ~s", [CallId]),

    {'noreply', State#state{current_member_calls = [Call | lists:keydelete(CallId, 2, CurrentCalls)]}};

handle_cast({'handle_queue_member_remove', JObj}, State) ->
    State1 = maybe_remove_queue_member(wh_json:get_value(<<"Call-ID">>, JObj), State),
    State2 = maybe_remove_callback_reg(wh_json:get_value(<<"Call-ID">>, JObj), State1),
    {'noreply', State2};

handle_cast({'handle_member_callback_reg', JObj}, #state{account_id=AccountId
                                                         ,queue_id=QueueId
                                                         ,current_member_calls=CurrentCalls
                                                         ,pos_announce_pids=Pids
                                                         ,registered_callbacks=RegCallbacks}=State) ->
    CallId = wh_json:get_value(<<"Call-ID">>, JObj),
    case lists:keyfind(CallId, 2, CurrentCalls) of
        'false' ->
            lager:debug("not accepting callback reg for ~s (call not in my list of calls)", [CallId]),
            {'noreply', State};
        Call ->
            lager:debug("call ~s marked as callback", [CallId]),
            Number = wh_json:get_value(<<"Number">>, JObj),
            Call1 = callback_flag(AccountId, QueueId, Call),
            CIDPrepend = whapps_call:kvs_fetch('prepend_cid_name', Call1),
            {'noreply', State#state{current_member_calls=lists:keyreplace(CallId, 2, CurrentCalls, Call1)
                                    ,pos_announce_pids=maybe_cancel_position_announcements(Call1, Pids)
                                    ,registered_callbacks=[{CallId, {Number, CIDPrepend}} | RegCallbacks]
                                   }}
    end;

handle_cast(_Msg, State) ->
    lager:debug("unhandled cast: ~p", [_Msg]),
    {'noreply', State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {'noreply', State} |
%%                                   {'noreply', State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    lager:debug("unhandled message: ~p", [_Info]),
    {'noreply', State}.

handle_event(_JObj, #state{enter_when_empty=EnterWhenEmpty
                           ,moh=MOH
                          }) ->
    {'reply', [{'enter_when_empty', EnterWhenEmpty}
               ,{'moh', MOH}
              ]}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    lager:debug("queue manager terminating: ~p", [_Reason]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
start_secondary_queue(AccountId, QueueId) ->
    Self = self(),
    AccountDb = wh_util:format_account_db(AccountId),
    Priority = lookup_priority_levels(AccountDb, QueueId),
    _ = wh_util:spawn(
          fun() -> gen_listener:add_queue(Self
                                          ,?SECONDARY_QUEUE_NAME(QueueId)
                                          ,[{'queue_options', ?SECONDARY_QUEUE_OPTIONS(Priority)}
                                            ,{'consume_options', ?SECONDARY_CONSUME_OPTIONS}
                                           ]
                                          ,?SECONDARY_BINDINGS(AccountId, QueueId)
                                         )
          end).

-spec lookup_priority_levels(ne_binary(), ne_binary()) -> api_integer().
lookup_priority_levels(AccountDB, QueueId) ->
    case couch_mgr:open_cache_doc(AccountDB, QueueId) of
        {'ok', JObj} -> wh_json:get_value(<<"max_priority">>, JObj);
        _ -> 'undefined'
    end.

make_ignore_key(AccountId, QueueId, CallId) ->
    {AccountId, QueueId, CallId}.

-spec publish_queue_member_add(ne_binary(), ne_binary(), wh_json:object()) -> 'ok'.
publish_queue_member_add(AccountId, QueueId, JObj) ->
    Prop = [{<<"Account-ID">>, AccountId}
            ,{<<"Queue-ID">>, QueueId}
            ,{<<"JObj">>, JObj}
            | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    wapi_acdc_queue:publish_queue_member_add(Prop).

-spec publish_queue_member_remove(ne_binary(), ne_binary(), wh_json:object()) -> 'ok'.
publish_queue_member_remove(AccountId, QueueId, JObj) ->
    Prop = [{<<"Account-ID">>, AccountId}
            ,{<<"Queue-ID">>, QueueId}
            ,{<<"JObj">>, JObj}
            | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    wapi_acdc_queue:publish_queue_member_remove(Prop).

-spec start_agent_and_worker(pid(), ne_binary(), ne_binary(), wh_json:object()) -> 'ok'.
start_agent_and_worker(WorkersSup, AccountId, QueueId, AgentJObj) ->
    acdc_queue_workers_sup:new_worker(WorkersSup, AccountId, QueueId),
    AgentId = wh_doc:id(AgentJObj),
    case acdc_agent_util:most_recent_status(AccountId, AgentId) of
        {'ok', <<"logout">>} -> 'ok';
        {'ok', <<"logged_out">>} -> 'ok';
        {'ok', _Status} ->
            lager:debug("maybe starting agent ~s(~s) for queue ~s", [AgentId, _Status, QueueId]),

            case acdc_agents_sup:find_agent_supervisor(AccountId, AgentId) of
                'undefined' -> acdc_agents_sup:new(AgentJObj);
                P when is_pid(P) -> 'ok'
            end
    end.

%% Really sophisticated selection algorithm
-spec pick_winner(pid(), wh_json:objects(), queue_strategy(), api_binary()) ->
                         'undefined' |
                         {wh_json:objects(), wh_json:objects()}.
pick_winner(_, [], _, _) ->
    lager:debug("no agent responses are left to choose from"),
    'undefined';
pick_winner(Mgr, CRs, 'rr', AgentId) ->
    case split_agents(AgentId, CRs) of
        {[], _O} ->
            lager:debug("oops, agent ~s appears to have not responded; try again", [AgentId]),
            pick_winner(Mgr, remove_unknown_agents(Mgr, CRs), 'rr', next_winner(Mgr));
        {Winners, OtherAgents} ->
            lager:debug("found winning responders for agent: ~s", [AgentId]),
            {Winners, OtherAgents}
    end;
pick_winner(_Mgr, CRs, 'mi', _) ->
    [MostIdle | Rest] = lists:usort(fun sort_agent/2, CRs),
    AgentId = wh_json:get_value(<<"Agent-ID">>, MostIdle),
    {Same, Other} = split_agents(AgentId, Rest),

    {[MostIdle|Same], Other}.

-spec update_strategy_with_agent(queue_strategy(), strategy_state(), ne_binary(), 'add' | 'remove', 'busy' | 'undefined') ->
                                        strategy_state().
update_strategy_with_agent('rr', #strategy_state{agents=AgentQueue}=SS, AgentId, 'add', Busy) ->
    case queue:member(AgentId, AgentQueue) of
        'true' -> set_busy(AgentId, Busy, SS);
        'false' -> set_busy(AgentId, Busy, add_agent('rr', AgentId, SS))
    end;
update_strategy_with_agent('rr', SS, AgentId, 'remove', 'busy') ->
    set_busy(AgentId, 'busy', SS);
update_strategy_with_agent('rr', #strategy_state{agents=AgentQueue}=SS, AgentId, 'remove', Busy) ->
    case queue:member(AgentId, AgentQueue) of
        'false' -> set_busy(AgentId, Busy, SS);
        'true' -> set_busy(AgentId, Busy, remove_agent('rr', AgentId, SS))
    end;
update_strategy_with_agent('mi', #strategy_state{agents=AgentL}=SS, AgentId, 'add', Busy) ->
    case lists:member(AgentId, AgentL) of
        'true' -> set_busy(AgentId, Busy, SS);
        'false' -> set_busy(AgentId, Busy, add_agent('mi', AgentId, SS))
    end;
update_strategy_with_agent('mi', SS, AgentId, 'remove', 'busy') ->
    set_busy(AgentId, 'busy', SS);
update_strategy_with_agent('mi', #strategy_state{agents=AgentL}=SS, AgentId, 'remove', Busy) ->
    case lists:member(AgentId, AgentL) of
        'false' -> set_busy(AgentId, Busy, SS);
        'true' -> set_busy(AgentId, Busy, remove_agent('mi', AgentId, SS))
    end.

-spec add_agent(queue_strategy(), ne_binary(), strategy_state()) -> strategy_state().
add_agent('rr', AgentId, #strategy_state{agents=AgentQueue
                                         ,details=Details
                                        }=SS) ->
    SS#strategy_state{agents=queue:in(AgentId, AgentQueue)
                      ,details=incr_agent(AgentId, Details)
                     };
add_agent('mi', AgentId, #strategy_state{agents=AgentL
                                         ,details=Details
                                        }=SS) ->
    SS#strategy_state{agents=[AgentId | AgentL]
                      ,details=incr_agent(AgentId, Details)
                     }.

-spec remove_agent(queue_strategy(), ne_binary(), strategy_state()) -> strategy_state().
remove_agent('rr', AgentId, #strategy_state{agents=AgentQueue
                                            ,details=Details
                                           }=SS) ->
    case dict:find(AgentId, Details) of
        {'ok', {Count, _}} when Count > 1 ->
            SS#strategy_state{details=decr_agent(AgentId, Details)};
        _ ->
            SS#strategy_state{agents=queue:filter(fun(AgentId1) when AgentId =:= AgentId1 -> 'false';
                                                     (_) -> 'true' end
                                                  ,AgentQueue
                                                 )
                              ,details=decr_agent(AgentId, Details)
                             }
    end;
remove_agent('mi', AgentId, #strategy_state{agents=AgentL
                                            ,details=Details
                                           }=SS) ->
    case dict:find(AgentId, Details) of
        {'ok', {Count, _}} when Count > 1 ->
            SS#strategy_state{details=decr_agent(AgentId, Details)};
        _ ->
            SS#strategy_state{agents=[A || A <- AgentL, A =/= AgentId]
                              ,details=decr_agent(AgentId, Details)
                             }
    end.

-spec incr_agent(ne_binary(), dict(ne_binary(), ss_details())) -> dict(ne_binary(), ss_details()).
incr_agent(AgentId, Details) ->
    dict:update(AgentId, fun({Count, Busy}) -> {Count + 1, Busy} end, {1, 'undefined'}, Details).

-spec decr_agent(ne_binary(), dict(ne_binary(), ss_details())) -> dict(ne_binary(), ss_details()).
decr_agent(AgentId, Details) ->
    dict:update(AgentId, fun({Count, Busy}) when Count > 1 -> {Count - 1, Busy};
                            ({_, Busy}) -> {0, Busy} end
                ,{0, 'undefined'}, Details).

-spec set_busy(ne_binary(), 'busy' | 'undefined', strategy_state()) -> strategy_state().
set_busy(AgentId, Busy, #strategy_state{details=Details}=SS) ->
    SS#strategy_state{details=dict:update(AgentId, fun({Count, _}) -> {Count, Busy} end, {0, Busy}, Details)}.

maybe_update_strategy('mi', StrategyState, _AgentId) -> StrategyState;
maybe_update_strategy('rr', #strategy_state{agents=AgentQueue}=SS, AgentId) ->
    case queue:out(AgentQueue) of
        {{'value', AgentId}, AgentQueue1} ->
            lager:debug("agent ~s was front of queue, moving", [AgentId]),
            SS#strategy_state{agents=queue:in(AgentId, AgentQueue1)};
        _ -> SS
    end.

%% If A's idle time is greater, it should come before B
-spec sort_agent(wh_json:object(), wh_json:object()) -> boolean().
sort_agent(A, B) ->
    sort_agent2(wh_json:get_integer_value(<<"Idle-Time">>, A)
                ,wh_json:get_integer_value(<<"Idle-Time">>, B)).

-spec sort_agent2(api_integer(), api_integer()) -> boolean().
sort_agent2('undefined', _) -> 'true';
sort_agent2(_, 'undefined') -> 'false';
sort_agent2(A, B) -> A > B.

%% Handle when an agent process has responded to the connect_req
%% but then the agent logs out of their phone (removing the agent
%% from the list in the queue manager).
%% Otherwise CRs will never be empty
-spec remove_unknown_agents(pid(), wh_json:objects()) -> wh_json:objects().
remove_unknown_agents(Mgr, CRs) ->
    case gen_listener:call(Mgr, 'current_agents') of
        [] -> [];
        Agents ->
            [CR || CR <- CRs,
                   lists:member(wh_json:get_value(<<"Agent-ID">>, CR), Agents)
            ]
    end.

-spec split_agents(ne_binary(), wh_json:objects()) ->
                          {wh_json:objects(), wh_json:objects()}.
split_agents(AgentId, Rest) ->
    lists:partition(fun(R) ->
                            AgentId =:= wh_json:get_value(<<"Agent-ID">>, R)
                    end, Rest).

-spec get_strategy(api_binary()) -> queue_strategy().
get_strategy(<<"round_robin">>) -> 'rr';
get_strategy(<<"most_idle">>) -> 'mi';
get_strategy(_) -> 'rr'.

-spec create_strategy_state(queue_strategy()
                            ,strategy_state()
                            ,ne_binary(), ne_binary()
                           ) -> strategy_state().
create_strategy_state(Strategy, AcctDb, QueueId) ->
    create_strategy_state(Strategy, #strategy_state{}, AcctDb, QueueId).

create_strategy_state('rr', #strategy_state{agents='undefined'}=SS, AcctDb, QueueId) ->
    create_strategy_state('rr', SS#strategy_state{agents=queue:new()}, AcctDb, QueueId);
create_strategy_state('rr', #strategy_state{agents=AgentQ}=SS, AcctDb, QueueId) ->
    case couch_mgr:get_results(AcctDb, <<"queues/agents_listing">>, [{'key', QueueId}]) of
        {'ok', []} -> lager:debug("no agents around"), SS;
        {'ok', JObjs} ->
            Q = queue:from_list([Id || JObj <- JObjs,
                                       not queue:member((Id = wh_doc:id(JObj)), AgentQ)
                                ]),
            Details = lists:foldl(fun(JObj, Acc) ->
                                          dict:store(wh_doc:id(JObj), {1, 'undefined'}, Acc)
                                  end, dict:new(), JObjs),
            SS#strategy_state{agents=queue:join(AgentQ, Q)
                              ,details=Details
                             };
        {'error', _E} -> lager:debug("error creating strategy rr: ~p", [_E]), SS
    end;
create_strategy_state('mi', #strategy_state{agents='undefined'}=SS, AcctDb, QueueId) ->
    create_strategy_state('mi', SS#strategy_state{agents=[]}, AcctDb, QueueId);
create_strategy_state('mi', #strategy_state{agents=AgentL}=SS, AcctDb, QueueId) ->
    case couch_mgr:get_results(AcctDb, <<"queues/agents_listing">>, [{key, QueueId}]) of
        {'ok', []} -> lager:debug("no agents around"), SS;
        {'ok', JObjs} ->
            AgentL1 = lists:foldl(fun(JObj, Acc) ->
                                          Id = wh_doc:id(JObj),
                                          case lists:member(Id, Acc) of
                                              'true' -> Acc;
                                              'false' -> [Id | Acc]
                                          end
                                  end, AgentL, JObjs),
            Details = lists:foldl(fun(JObj, Acc) ->
                                          dict:store(wh_doc:id(JObj), {1, 'undefined'}, Acc)
                                  end, dict:new(), JObjs),
            SS#strategy_state{agents=AgentL1
                              ,details=Details
                             };
        {'error', _E} -> lager:debug("error creating strategy mi: ~p", [_E]), SS
    end.

update_strategy_state(Srv, 'rr', #strategy_state{agents=AgentQueue}) ->
    L = queue:to_list(AgentQueue),
    update_strategy_state(Srv, L);
update_strategy_state(Srv, 'mi', #strategy_state{agents=AgentL}) ->
    update_strategy_state(Srv, AgentL).
update_strategy_state(Srv, L) ->
    [gen_listener:cast(Srv, {'sync_with_agent', A}) || A <- L].

-spec ss_size(strategy_state(), 'free' | 'logged_in') -> integer().
ss_size(#strategy_state{agents=Agents}, 'logged_in') ->
    case queue:is_queue(Agents) of
        'true' -> queue:len(Agents);
        'false' -> length(Agents)
    end;
ss_size(#strategy_state{agents=Agents
                        ,details=Details
                       }, 'free') when is_list(Agents) ->
    lists:foldl(fun(AgentId, Count) ->
                        case dict:find(AgentId, Details) of
                            {'ok', {ProcCount, 'undefined'}} when ProcCount > 0 -> Count + 1;
                            _ -> Count
                        end
                end, 0, Agents);
ss_size(#strategy_state{agents=Agents}=SS, 'free') ->
    ss_size(SS#strategy_state{agents=queue:to_list(Agents)}, 'free').

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns true if CallId is within the first Max elements of Calls
%%
%% @end
%%--------------------------------------------------------------------
-spec up_next_fold([whapps_call:call()], ne_binary(), integer()) -> boolean().
up_next_fold(Calls, _, Max) when Max >= length(Calls) -> 'true';
up_next_fold(_, _, 0) -> 'false';
up_next_fold([Call|Calls], CallId, Max) ->
    case whapps_call:call_id(Call) of
        CallId -> 'true';
        _ -> up_next_fold(Calls, CallId, Max-1)
    end.

maybe_start_queue_workers(QueueSup, AgentCount) ->
    WSup = acdc_queue_sup:workers_sup(QueueSup),
    case acdc_queue_workers_sup:worker_count(WSup) of
        N when N >= AgentCount -> 'ok';
        N when N < AgentCount -> gen_listener:cast(self(), {'start_worker', AgentCount-N})
    end.

-spec update_properties(wh_json:object(), mgr_state()) -> mgr_state().
update_properties(QueueJObj, State) ->
    Default = #state{},
    State#state{
      enter_when_empty=wh_json:is_true(<<"enter_when_empty">>, QueueJObj, 'true')
      ,moh=wh_json:get_ne_value(<<"moh">>, QueueJObj)
      ,pos_announce_enabled=wh_json:is_true(<<"position_announcements_enabled">>, QueueJObj, 'false')
      ,wait_announce_enabled=wh_json:is_true(<<"holdtime_announcements_enabled">>, QueueJObj, 'false')
      ,announcements_timer=wh_json:get_integer_value(<<"announcements_timer">>, QueueJObj, 30)

      ,position_media = wh_json:get_value(<<"position_media">>, QueueJObj, Default#state.position_media)
      ,in_the_queue_media = wh_json:get_value(<<"in_the_queue_media">>, QueueJObj, Default#state.in_the_queue_media)
      ,increase_call_volume_media = wh_json:get_value(<<"increase_call_volume_media">>, QueueJObj, Default#state.increase_call_volume_media)
      ,estimated_wait_time_media = wh_json:get_value(<<"estimated_wait_time_media">>, QueueJObj, Default#state.estimated_wait_time_media)
     }.

-spec announce_position(whapps_call:call(), ne_binary(), non_neg_integer(), {boolean(), boolean()}, proplist(), non_neg_integer() | 'undefined') ->
        non_neg_integer() | 'undefined'.
announce_position(Call, QueueId, Position, {PosAnnounceEnabled, WaitAnnounceEnabled}, Media, OldAverageWait) ->
    Req = props:filter_undefined(
            [{<<"Account-ID">>, whapps_call:account_id(Call)}
             ,{<<"Queue-ID">>, QueueId}
             | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
            ]),
    case whapps_util:amqp_pool_request(Req
                                       ,fun wapi_acdc_stats:publish_current_calls_req/1
                                       ,fun wapi_acdc_stats:current_calls_resp_v/1
                                      )
    of
        {'error', _E} ->
            lager:debug("failed to recv resp from AMQP: ~p", [_E]),
            'undefined';
        {'ok', Resp} ->
            {AverageWait, Prompts} = maybe_average_wait_announcement(Resp, WaitAnnounceEnabled, Media, whapps_call:language(Call), OldAverageWait),
            Prompt = maybe_position_announcement(Position, PosAnnounceEnabled, Media, whapps_call:language(Call)) ++
                       Prompts,
            whapps_call_command:audio_macro(Prompt, Call),
            AverageWait
    end.

-spec maybe_position_announcement(non_neg_integer(), boolean(), proplist(), binary()) -> list().
maybe_position_announcement(_, 'false', _, _) ->
    [];
maybe_position_announcement(Position, 'true', Media, Language) ->
    lager:debug("position ~p", [Position]),
    [{'prompt', props:get_value(<<"position_media">>, Media), Language, <<"A">>}
     ,{'say', wh_util:to_binary(Position), <<"number">>}
     ,{'prompt', props:get_value(<<"in_the_queue_media">>, Media), Language, <<"A">>}].

-spec maybe_average_wait_announcement(wh_json:object(), boolean(), proplist(), binary(), non_neg_integer() | 'undefined') ->
        {non_neg_integer() | 'undefined', list()}.
maybe_average_wait_announcement(_, 'false', _, _, _) ->
    {'undefined', []};
maybe_average_wait_announcement(JObj, 'true', Media, Language, OldAverageWait) ->
    average_wait_announcement(JObj, Media, Language, OldAverageWait).

-spec average_wait_announcement(wh_json:object(), proplist(), binary(), non_neg_integer() | 'undefined') -> {non_neg_integer() | 'undefined', list()}.
average_wait_announcement(JObj, Media, Language, OldAverageWait) ->
    Abandoned = length(wh_json:get_value(<<"Abandoned">>, JObj, [])),
    Total = length(wh_json:get_value(<<"Abandoned">>, JObj, [])) +
              length(wh_json:get_value(<<"Handled">>, JObj, [])) +
              length(wh_json:get_value(<<"Processed">>, JObj, [])),
    TotalWait = lists:foldl(fun(Key, Acc) ->
      CallList = wh_json:get_value(Key, JObj, []),
      Acc + lists:foldl(fun(Call, Acc2) ->
        Acc2 + wh_json:get_value(<<"wait_time">>, Call, 0)
        end
        ,0
        ,CallList)
      end
      ,0
      ,[<<"Waiting">>, <<"Handled">>, <<"Processed">>]),
    time_prompts(format_time(calc_average_wait(Abandoned, Total, TotalWait)), OldAverageWait, Media, Language).

calc_average_wait(Same, Same, TotalWait) ->
    TotalWait;
calc_average_wait(Abandoned, Total, TotalWait) ->
    TotalWait div (Total - Abandoned).

format_time(Time) ->
    {Time div 3600, Time rem 3600 div 60, Time rem 60}.

time_prompts({0, 0, 0}=AverageWait, _, _, _) ->
    {AverageWait, []};
time_prompts({Hour, Min, Sec}=Time, {Hour2, Min2, Sec2}, Media, Language) when (Hour * 3600 + Min * 60 + Sec) > (Hour2 * 3600 + Min2 * 60 + Sec2) ->
    {Time, [{'prompt', props:get_value(<<"increase_call_volume_media">>, Media), Language, <<"A">>}
            ,{'prompt', props:get_value(<<"estimated_wait_time_media">>, Media), Language, <<"A">>}
            | time_prompts2(Time, Language)
           ]};
time_prompts(Time, _, Media, Language) ->
    {Time, [{'prompt', props:get_value(<<"estimated_wait_time_media">>, Media), Language, <<"A">>}
            | time_prompts2(Time, Language)
           ]}.

time_prompts2({0, 0, _}, Language) ->
    [{'prompt', <<"queue-less_than_1_minute">>, Language, <<"A">>}];
time_prompts2({0, Min, _}, Language) when Min =< 5 ->
    [{'prompt', <<"queue-about_5_minutes">>, Language, <<"A">>}];
time_prompts2({0, Min, _}, Language) when Min =< 10 ->
    [{'prompt', <<"queue-about_10_minutes">>, Language, <<"A">>}];
time_prompts2({0, Min, _}, Language) when Min =< 15 ->
    [{'prompt', <<"queue-about_15_minutes">>, Language, <<"A">>}];
time_prompts2({0, Min, _}, Language) when Min =< 30 ->
    [{'prompt', <<"queue-about_30_minutes">>, Language, <<"A">>}];
time_prompts2({0, Min, _}, Language) when Min =< 45 ->
    [{'prompt', <<"queue-about_45_minutes">>, Language, <<"A">>}];
time_prompts2({0, _, _}, Language) ->
    [{'prompt', <<"queue-about_1_hour">>, Language, <<"A">>}];
time_prompts2({_, _, _}, Language) ->
    [{'prompt', <<"queue-at_least_1_hour">>, Language, <<"A">>}].

queue_media_list(#state{position_media=PositionMedia
                        ,in_the_queue_media=InTheQueueMedia
                        ,increase_call_volume_media=IncreaseCallVolumeMedia
                        ,estimated_wait_time_media=EstimatedWaitTimeMedia
                       }) ->
    [{<<"position_media">>, PositionMedia}
     ,{<<"in_the_queue_media">>, InTheQueueMedia}
     ,{<<"increase_call_volume_media">>, IncreaseCallVolumeMedia}
     ,{<<"estimated_wait_time_media">>, EstimatedWaitTimeMedia}
    ].

announce_position_loop(Srv, Call, QueueId, AnnouncesEnabled, AnnouncementsTimer, Media, LastAverage) ->
    Position = gen_listener:call(Srv, {'queue_position', whapps_call:call_id(Call)}),
    NewAverage = announce_position(Call, QueueId, Position, AnnouncesEnabled, Media, LastAverage),
    timer:sleep(AnnouncementsTimer * 1000),
    announce_position_loop(Srv, Call, QueueId, AnnouncesEnabled, AnnouncementsTimer, Media, NewAverage).

-spec maybe_schedule_position_announcements(whapps_call:call()
                                            ,ne_binary()
                                            ,{boolean(), boolean()}
                                            ,proplist()
                                            ,non_neg_integer()
                                            ,announce_pid_list()
                                           ) -> announce_pid_list().
maybe_schedule_position_announcements(_Call, _, {'false', 'false'}, _, _, Pids) ->
    Pids;
maybe_schedule_position_announcements(Call, QueueId, AnnouncesEnabled, AnnouncementsTimer, Media, Pids) when AnnouncementsTimer < 30 ->
    maybe_schedule_position_announcements(Call, QueueId, AnnouncesEnabled, 30, Media, Pids);
maybe_schedule_position_announcements(Call, QueueId, AnnouncesEnabled, AnnouncementsTimer, Media, Pids) ->
    [{whapps_call:call_id(Call), spawn(
                                   ?MODULE
                                   ,'announce_position_loop'
                                   ,[self(), Call, QueueId, AnnouncesEnabled, AnnouncementsTimer, Media, 'undefined']
                                   )} | Pids].

-spec maybe_cancel_position_announcements(whapps_call:call(), announce_pid_list()) -> announce_pid_list().
maybe_cancel_position_announcements(Call, Pids) ->
    CallId = whapps_call:call_id(Call),
    case lists:keyfind(CallId, 1, Pids) of
        {_, Pid} ->
            erlang:exit(Pid, 'call_done'),
            %% Attempt to skip remaining announcement media, but don't flush hangups
            NoopId = couch_mgr:get_uuid(),
            Command = [{<<"Application-Name">>, <<"noop">>}
                       ,{<<"Msg-ID">>, NoopId}
                       ,{<<"Insert-At">>, <<"now">>}
                       ,{<<"Filter-Applications">>, [<<"play">>, <<"say">>, <<"play">>]}
                      ],
            whapps_call_command:send_command(Command, Call);
        _ ->
            lager:debug("she caught me without the pid... it wasn't me"),
            'ok'
    end,
    lists:keydelete(whapps_call:call_id(Call), 1, Pids).

-spec maybe_remove_queue_member(api_binary(), mgr_state()) -> mgr_state().
maybe_remove_queue_member(CallId, #state{account_id=AccountId
                                         ,queue_id=QueueId
                                         ,current_member_calls=CurrentCalls
                                         ,pos_announce_pids=Pids
                                        }=State) ->
    Call = lists:keyfind(CallId, 2, CurrentCalls),

    {Map, _} = lists:mapfoldr(fun(X, I) -> {{X, I}, I + 1} end, 1, CurrentCalls),
    Index = case lists:keyfind(Call, 1, Map) of
        {_, Index2} ->
            lager:debug("removing call id ~s", [CallId]),
            Index2;
        _Result ->
            lager:debug("call id ~p", [CallId]),
            lists:foreach(fun(Call2) ->
                lager:debug("current call id ~p", [whapps_call:call_id(Call2)])
            end, CurrentCalls),
            'undefined'
    end,

    Prop = [{<<"Account-ID">>, AccountId}
            ,{<<"Queue-ID">>, QueueId}
            ,{<<"Call-ID">>, CallId}
            ,{<<"Exited-Position">>, Index}
            | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],

    case Index of
        'undefined' -> 'ok';
        _Other -> wapi_acdc_stats:publish_call_exited_position(Prop)
    end,

    UpdatedMemberCalls = lists:delete(Call, CurrentCalls),

    %% Cancel position announcements
    UpdatedAnnouncePids = case lists:keyfind(CallId, 2, CurrentCalls) of
        'false' -> Pids;
        Call -> maybe_cancel_position_announcements(Call, Pids)
    end,

    State#state{current_member_calls=UpdatedMemberCalls
                ,pos_announce_pids=UpdatedAnnouncePids
               }.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Prepend CB: onto CID of callback calls and flag call ID as callback
%% in acdc_stats
%%
%% @end
%%--------------------------------------------------------------------
-spec callback_flag(ne_binary(), ne_binary(), whapps_call:call()) ->
                           whapps_call:call().
callback_flag(AccountId, QueueId, Call) ->
    Call1 = prepend_cid_name(<<"CB:">>, Call),
    {_, CIDName} = acdc_util:caller_id(Call1),
    acdc_stats:call_marked_callback(AccountId
                                    ,QueueId
                                    ,whapps_call:call_id(Call)
                                    ,CIDName
                                   ),
    Call1.

-spec prepend_cid_name(ne_binary(), whapps_call:call()) -> whapps_call:call().
prepend_cid_name(Prefix, Call) ->
    Prefix1 = case whapps_call:kvs_fetch('prepend_cid_name', Call) of
                  'undefined' -> Prefix;
                  Prepend -> <<Prefix/binary, Prepend/binary>>
              end,
    whapps_call:kvs_store('prepend_cid_name', Prefix1, Call).

-spec maybe_remove_callback_reg(ne_binary(), mgr_state()) -> mgr_state().
maybe_remove_callback_reg(CallId, #state{registered_callbacks=RegCallbacks}=State) ->
    State#state{registered_callbacks=lists:keydelete(CallId, 1, RegCallbacks)}.
