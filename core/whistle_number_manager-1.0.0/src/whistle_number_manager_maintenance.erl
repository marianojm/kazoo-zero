%%%-------------------------------------------------------------------
%%% @copyright (C) 2010-2015, 2600Hz INC
%%% @doc
%%% Preforms maintenance operations against the stepswitch dbs
%%% @end
%%% @contributors
%%%   Karl Anderson
%%%-------------------------------------------------------------------
-module(whistle_number_manager_maintenance).

-export([refresh/0]).
-export([reconcile/0, reconcile/1]).
-export([reconcile_numbers/0, reconcile_numbers/1]).
-export([reconcile_accounts/0, reconcile_accounts/1]).

-export([reconcile_providers/0]).

-export([cleanup_phone_numbers/0, cleanup_phone_numbers/1]).

-export([create_phone_number/1, create_phone_number/2]).
-export([activate_phone_number/1, activate_phone_number/2]).
-export([create_and_activate_phone_number/2]).

-include("wnm.hrl").
-include_lib("whistle_number_manager/include/wh_number_manager.hrl").

%% These are temporary until the viewing of numbers in an account can
%% be standardized
-define(TS_DB, <<"ts">>).

%% TODO: This makes stepswitch dependent on callflow view... This is safe-ish
%% beacuse if you reconcile without the callflow view then they will never
%% run anyway (no callflow whapp connected to the db to execute). But it is
%% still nasty...
-define(CALLFLOW_VIEW, <<"callflows/listing_by_number">>).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec refresh() -> 'ok'.
refresh() ->
    Views = whapps_util:get_views_json('whistle_number_manager', "views"),
    _ = [begin
             Db = wh_util:to_binary(http_uri:encode(wh_util:to_list(NumberDb))),
             whapps_util:update_views(Db, Views, 'true')
         end
         || NumberDb <- wnm_util:get_all_number_dbs()
        ],
    'ok'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Seach the accounts for number assignements and ensure the routes
%% exist
%% @end
%%--------------------------------------------------------------------
-spec reconcile() -> 'no_return'.
-spec reconcile(string() | ne_binary() | 'all') -> 'no_return'.

reconcile() ->
    io:format("This command is depreciated, please use reconcile_numbers() or for older systems reconcile_accounts(). See the wiki for details on the differences."),
    'no_return'.

reconcile(Arg) ->
    io:format("This command is depreciated, please use reconcile_numbers() or for older systems reconcile_accounts(~s). See the wiki for details on the differences.", [Arg]),
    'no_return'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Seach the number databases and ensure all assignments are reflected
%% in the accounts
%% @end
%%--------------------------------------------------------------------
-spec reconcile_numbers() -> 'no_return' | {'error', any()}.
-spec reconcile_numbers(string() | ne_binary() | 'all') -> 'no_return' | {'error', any()}.

reconcile_numbers() ->
    reconcile_numbers('all').

reconcile_numbers('all') ->
    _ = [reconcile_numbers(Db)
         || Db <- wnm_util:get_all_number_dbs()
        ],
    'no_return';
reconcile_numbers(NumberDb) when not is_binary(NumberDb) ->
    reconcile_numbers(wh_util:to_binary(NumberDb));
reconcile_numbers(NumberDb) ->
    Db = wh_util:to_binary(http_uri:encode(wh_util:to_list(NumberDb))),
    case couch_mgr:all_docs(Db) of
        {'error', _R}=E -> E;
        {'ok', JObjs} ->
            Numbers = [Number
                       || JObj <- JObjs
                              ,case (Number = wh_doc:id(JObj)) of
                                   <<"_design/", _/binary>> -> 'false';
                                   _Else -> 'true'
                               end
                      ],
            _ = reconcile_numbers(Numbers, 'system'),
            'no_return'
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Seach the accounts for phone numbers and ensure the number is routed
%% to the account (first account found with a duplicate number will win)
%% @end
%%--------------------------------------------------------------------
-spec reconcile_accounts() -> 'no_return'.
-spec reconcile_accounts(string() | ne_binary() | 'all') -> 'no_return'.

reconcile_accounts() ->
    reconcile_accounts('all').

reconcile_accounts('all') ->
    _ = [reconcile_accounts(AccountId) || AccountId <- whapps_util:get_all_accounts('raw')],
    'no_return';
reconcile_accounts(AccountId) when not is_binary(AccountId) ->
    reconcile_accounts(wh_util:to_binary(AccountId));
reconcile_accounts(AccountId) ->
    AccountDb = wh_util:format_account_id(AccountId, 'encoded'),
    Numbers = get_callflow_account_numbers(AccountDb),
    Numbers1 = get_trunkstore_account_numbers(AccountId, AccountDb) ++ Numbers,
    _ = reconcile_numbers(Numbers1, wh_util:format_account_id(AccountId, 'raw')),
    'no_return'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Load known provider modules into system_config
%% exist
%% @end
%%--------------------------------------------------------------------
-spec reconcile_providers() -> any().
-spec reconcile_providers(ne_binaries(), ne_binaries()) -> any().
reconcile_providers() ->
    Paths = filelib:wildcard([code:lib_dir('whistle_number_manager'), "/src/providers/*.erl"]),
    Mods = [wh_util:to_binary(filename:rootname(filename:basename(P))) || P <- Paths],

    lager:debug("Mods: ~p", [Mods]),

    Providers = whapps_config:get(?WNM_CONFIG_CAT, <<"providers">>, []),
    lager:debug("prov: ~p", [Providers]),

    reconcile_providers(Mods, Providers).

reconcile_providers([<<"wnm_", P/binary>>|Avail], Config) ->
    case lists:member(P, Config) of
        'true' -> reconcile_providers(Avail, Config);
        'false' -> reconcile_providers(Avail, [P | Config])
    end;
reconcile_providers([_|Avail], Config) ->
    reconcile_providers(Avail, Config);
reconcile_providers([], Config) ->
    whapps_config:set_default(?WNM_CONFIG_CAT, <<"providers">>, Config).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% exist
%% @end
%%--------------------------------------------------------------------
-spec cleanup_phone_numbers() -> 'ok'.
-spec cleanup_phone_numbers(ne_binary() | ne_binaries()) -> 'ok'.
cleanup_phone_numbers() ->
    Accounts = whapps_util:get_all_accounts('raw'),
    wh_number_fix:fix_account_numbers(Accounts).

cleanup_phone_numbers(Account) ->
    wh_number_fix:fix_account_numbers(Account).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% exist
%% @end
%%--------------------------------------------------------------------
-spec create_phone_number(ne_binary()) -> 'ok'.
-spec create_phone_number(ne_binary(), ne_binary()) -> 'ok'.
-spec create_phone_number(ne_binary(), ne_binary(), ne_binary()) ->
                                 {'ok', wh_json:object()} |
                                 {atom(), api_object()}.
create_phone_number(Number) ->
    {'ok', AccountId} = whapps_util:get_master_account_id(),
    create_phone_number(Number, AccountId).

create_phone_number(Number, AccountId) ->
    {'ok', SystemAccountId} = whapps_util:get_master_account_id(),
    case create_phone_number(Number, AccountId, SystemAccountId) of
        {'ok', JObj} ->
            io:format("successfully created ~s: ~s~n"
                      ,[Number, wh_json:encode(JObj)]
                     );
        {Error, Reason} ->
            io:format("failed to create ~s: ~s: ~p~n"
                      ,[Number, Error, Reason]
                     )
    end.

create_phone_number(Number, AccountId, SystemAccountId) ->
    wh_number_manager:create_number(Number
                                    ,AccountId
                                    ,SystemAccountId
                                   ).

-spec activate_phone_number(ne_binary()) -> 'ok'.
-spec activate_phone_number(ne_binary(), ne_binary()) -> 'ok'.
-spec activate_phone_number(ne_binary(), ne_binary(), ne_binary()) ->
                                   {'ok', wh_json:object()} |
                                   {atom(), api_object()}.
activate_phone_number(Number) ->
    {'ok', AccountId} = whapps_util:get_master_account_id(),
    activate_phone_number(Number, AccountId).

activate_phone_number(Number, AccountId) ->
    {'ok', SystemAccountId} = whapps_util:get_master_account_id(),
    case activate_phone_number(Number, AccountId, SystemAccountId) of
        {'ok', JObj} ->
            io:format("successfully activated ~s: ~s~n"
                      ,[Number, wh_json:encode(JObj)]
                     );
        {Error, Reason} ->
            io:format("failed to activate ~s: ~s: ~p~n"
                      ,[Number, Error, Reason]
                     )
    end.

activate_phone_number(Number, AccountId, SystemAccountId) ->
    wh_number_manager:assign_number_to_account(Number
                                               ,AccountId
                                               ,SystemAccountId
                                              ).

-spec create_and_activate_phone_number(ne_binary(), ne_binary()) -> 'ok'.
create_and_activate_phone_number(Number, AccountId) ->
    {'ok', SystemAccountId} = whapps_util:get_master_account_id(),

    {'ok', _} = create_phone_number(Number, AccountId, SystemAccountId),
    {'ok', JObj} = activate_phone_number(Number, AccountId, SystemAccountId),
    io:format("created and activated number: ~s", [wh_json:encode(JObj)]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Given an account create a json object of all numbers that look to
%% external (TODO: currently just uses US rules).
%% @end
%%--------------------------------------------------------------------
-spec get_callflow_account_numbers(ne_binary()) -> wh_json:keys().
get_callflow_account_numbers(AccountId) ->
    AccountDb = wh_util:format_account_id(AccountId, 'encoded'),
    case couch_mgr:get_all_results(AccountDb, ?CALLFLOW_VIEW) of
        {'ok', Numbers} ->
            [wh_json:get_value(<<"key">>, Number) || Number <- Numbers];
        {'error', _} ->
            []
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Given a document info json object from trunkstore returns true if
%% it is a 'info_' document (IE: trunkstore account)
%% @end
%%--------------------------------------------------------------------
-spec is_trunkstore_account(wh_json:object()) -> boolean().
is_trunkstore_account(JObj) ->
    wh_json:get_value(<<"type">>, JObj) =:= <<"sys_info">> orelse
        wh_doc:type(JObj) =:= <<"sys_info">>.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Given a trunkstore account id this function builds a json object
%% containing all numbers assigned to it
%% @end
%%--------------------------------------------------------------------
-spec get_trunkstore_account_numbers(ne_binary(), ne_binary()) -> ne_binaries().
get_trunkstore_account_numbers(AccountId, AccountDb) ->
    lager:debug("looking in ~s for trunkstore DIDs", [AccountDb]),
    case couch_mgr:get_results(AccountDb, <<"trunkstore/LookUpDID">>, []) of
        {'ok', []} ->
            lager:debug("no trunkstore DIDs listed in account ~s, trying ts db", [AccountDb]),
            get_trunkstore_account_numbers(AccountId);
        {'ok', JObjs} ->
            lager:debug("account db ~s has trunkstore DIDs", [AccountDb]),
            Assigned = [wh_json:get_value(<<"key">>, JObj) || JObj <- JObjs],

            TSDocId = wh_doc:id(hd(JObjs)),
            {'ok', TSDoc} = couch_mgr:open_doc(AccountDb, TSDocId),
            lager:debug("fetched ts doc ~s from ~s", [TSDocId, AccountDb]),

            wh_json:get_keys(wh_json:get_value(<<"DIDs_Unassigned">>, TSDoc, wh_json:new())) ++ Assigned;
        {'error', _} ->
            lager:debug("failed to find DIDs in account db, trying ts doc"),
            get_trunkstore_account_numbers(AccountId)
    end.

-spec get_trunkstore_account_numbers(ne_binary()) -> ne_binaries().
get_trunkstore_account_numbers(AccountId) ->
    case couch_mgr:open_doc(?TS_DB, AccountId) of
        {'ok', JObj} ->
            case is_trunkstore_account(JObj) of
                'true' ->
                    lager:debug("account ~s is a trunkstore doc...", [AccountId]),
                    Assigned = [wh_json:get_value(<<"DIDs">>, Server, wh_json:new())
                                || Server <- wh_json:get_value(<<"servers">>, JObj, wh_json:new())
                               ],
                    Unassigned = [wh_json:get_value(<<"DIDs_Unassigned">>, JObj, wh_json:new())],
                    lists:foldr(fun(Numbers, Acc) ->
                                        case wh_json:is_json_object(Numbers) of
                                            'true' ->
                                                wh_json:get_keys(Numbers) ++ Acc;
                                            'false' ->
                                                Acc
                                        end
                                end, [], Assigned ++ Unassigned);
                'false' -> []
            end;
        _ -> []
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Updates or creates a route document for the given account with the
%% provided numbers
%% @end
%%--------------------------------------------------------------------
-spec reconcile_numbers(ne_binaries(), 'system' | ne_binary()) -> 'ok'.
reconcile_numbers(Numbers, AccountId) ->
    reconcile_numbers(Numbers, AccountId, length(Numbers), 1).

reconcile_numbers([Number|Numbers], AccountId, Total, Count) ->
    Db = wnm_util:number_to_db_name(Number),
    ReconcileWith = case is_binary(AccountId) of 'true' -> AccountId; 'false' -> Db end,
    try wh_number_manager:reconcile_number(Number, AccountId, AccountId) of
        _ ->
            io:format("reconciled ~s number (~p/~p): ~s~n", [ReconcileWith, Count, Total, Number]),
            reconcile_numbers(Numbers, AccountId, Total, Count + 1)
    catch
        _E:_R ->
            io:format("error reconciling ~s number (~p/~p) ~s: ~p:~p~n", [ReconcileWith, Count, Total, Number, _E, _R]),
            reconcile_numbers(Numbers, AccountId, Total, Count + 1)
    end;
reconcile_numbers([], _, _, _) ->
    'ok'.
