-ifndef(CF_TEMPORAL_ROUTE_HRL).

-define(FIND_RULES, <<>>).

-type improper_month() :: non_neg_integer().
-type improper_day() :: non_neg_integer().
-type improper_date() :: {wh_year(), improper_month(), improper_day()}.
-type strict_ordinal() :: binary(). %%<<"first">> | <<"second">> | <<"third">> | <<"fourth">> | <<"fifth">>.
-type broad_ordinal() :: binary(). %%<<"every">> | <<"last">>.
-type ordinal() :: strict_ordinal() | broad_ordinal().

%% <<"monday">> | <<"tuesday">> | <<"wensday">> | <<"wednesday">> | <<"thursday">>
%% | <<"friday">> | <<"saturday">> | <<"sunday">>.
-type wday() :: binary().

-type cycle_type() :: binary(). %%<<"date">> | <<"daily">> | <<"weekly">> | <<"monthly">> | <<"yearly">>.

-record(keys, {enable = <<"1">> :: ne_binary()
               ,disable = <<"2">> :: ne_binary()
               ,reset = <<"3">> :: ne_binary()
              }).
-type keys() :: #keys{}.

-record(prompts, {marked_disabled = <<"temporal-marked_disabled">> :: ne_binary()
                  ,marked_enabled = <<"temporal-marked_enabled">> :: ne_binary()
                  ,marker_reset = <<"temporal-marker_reset">> :: ne_binary()
                  ,main_menu = <<"temporal-menu">> :: ne_binary()
                 }).
-type prompts() :: #prompts{}.

-define(RULE_DEFAULT_NAME, <<"no_name">>).
-define(RULE_DEFAULT_CYCLE, <<>>).
-define(RULE_DEFAULT_INTERVAL, 1).
-define(RULE_DEFAULT_DAYS, []).
-define(RULE_DEFAULT_WDAYS, []).
-define(RULE_DEFAULT_ORDINAL, <<"first">>).
-define(RULE_DEFAULT_MONTH, 1).
-define(RULE_DEFAULT_START_DATE, {2011,1,1}).
-define(RULE_DEFAULT_WTIME_START, 0).
-define(RULE_DEFAULT_WTIME_STOP, ?SECONDS_IN_DAY).

-record(rule, {id = <<>> :: binary()
               ,enabled :: api_boolean()
               ,name = ?RULE_DEFAULT_NAME :: binary()
               ,cycle = ?RULE_DEFAULT_CYCLE :: cycle_type()
               ,interval = ?RULE_DEFAULT_INTERVAL :: non_neg_integer()
               ,days = ?RULE_DEFAULT_DAYS :: [wh_day()]
               ,wdays = ?RULE_DEFAULT_WDAYS :: [wday()]
               ,ordinal = ?RULE_DEFAULT_ORDINAL :: ordinal()
               ,month = ?RULE_DEFAULT_MONTH :: wh_month()
               ,start_date = ?RULE_DEFAULT_START_DATE :: wh_date()
               ,wtime_start = ?RULE_DEFAULT_WTIME_START :: non_neg_integer()
               ,wtime_stop = ?RULE_DEFAULT_WTIME_STOP :: non_neg_integer()
               ,rule_set  = 'false' :: boolean()
              }).

-type rule() :: #rule{}.
-type rules() :: [rule()].

-record(temporal, {local_sec = 0 :: non_neg_integer()
                   ,local_date = {2011, 1, 1} :: wh_date()
                   ,local_time = {0, 0, 0} :: wh_time()
                   ,routes = [] :: wh_json:keys()
                   ,timezone :: api_binary()
                   ,prompts = #prompts{} :: prompts()
                   ,keys = #keys{} :: keys()
                   ,interdigit_timeout = whapps_call_command:default_interdigit_timeout() :: pos_integer()
                   ,rule_set = 'false' :: boolean()
                  }).
-type temporal() :: #temporal{}.

-define(CF_TEMPORAL_ROUTE_HRL, 'true').
-endif.
