%% -*- tab-width: 4;erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% ----------------------------------------------------------------------------
%%
%% Copyright (c) 2005 - 2012 Nebularis.
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
%% IN THE SOFTWARE.
%% ----------------------------------------------------------------------------
%% @hidden
%% ----------------------------------------------------------------------------
-module(systest_cli).

-behaviour(systest_proc).

%% TODO: migrate to ?SYSTEST_LOG

-compile({no_auto_import, [open_port/2]}).

%% API Exports

-export([init/1, handle_stop/2, handle_kill/2]).
-export([handle_status/2, handle_interaction/3,
         handle_msg/3, terminate/3]).

%% private record for tracking...
-record(sh, {
    id,  %% NB: this is just a convenience
    start_command,
    stop_command,
    state,
    log,
    rpc_enabled,
    pid,
    port,
    detached,
    shutdown_port
}).

-record(exec, {
    command,
    argv,
    environment
}).

-define(IS_DYING(State),
        State =:= killed orelse State =:= stopped).

-include("systest.hrl").

-import(systest_log, [log/2, log/3]).

%%
%% systest_proc API
%%

init(Proc=#proc{config=Config}) ->

    %% TODO: don't carry all the config around all the time -
    %% e.g., append the {proc, NI} tuple only when needed

    Scope = systest_proc:get(scope, Proc),
    Id = systest_proc:get(id, Proc),
    Config = systest_proc:get(config, Proc),
    Flags = systest_proc:get(flags, Proc),

    Startup = ?CONFIG(startup, Config, []),
    Detached = ?REQUIRE(detached, Startup),
    {RpcEnabled, ShutdownSpec} = ?CONFIG(rpc_enabled,
                                         Startup, {true, default}),

    StartCmd = make_exec(start, Detached, RpcEnabled, Config),
    StopCmd  = stop_flags(Flags, ShutdownSpec, Detached, RpcEnabled, Config),

    case check_command_mode(Detached, RpcEnabled) of
        ok ->
            Port = open_port(StartCmd, Detached),
            #exec{environment=Env} = StartCmd,

            if Detached =:= true -> link(Port);
                            true -> ok
            end,

            on_startup(Scope, Id, Port, Detached, RpcEnabled, Env, Config,
                fun(Port2, Pid, LogFd) ->
                    %% NB: as not all kinds of procs can be contacted
                    %% via rpc, we have to do this manually here....
                    if RpcEnabled =:= true -> erlang:monitor_node(Id, true);
                                      true -> ok
                    end,

                    N2 = Proc#proc{os_pid=Pid,
                                    user=[{env, Env}|
                                          Proc#proc.user]},
                    Sh = #sh{id=Id,
                             pid=Pid,
                             port=Port2,
                             detached=Detached,
                             log=LogFd,
                             rpc_enabled=RpcEnabled,
                             start_command=StartCmd,
                             stop_command=StopCmd,
                             state=running},
                    log(framework,
                        "external process handler ~p[~p]"
                        " started at ~p~n", [Scope, Id, self()]),
                    {ok, N2, Sh}
                end);
        StopError ->
            StopError
    end.

%% @doc handles interactions with the proc.
%% handle_interaction(Data, Proc, State) -> {reply, Reply, NewProc, NewState} |
%%                                          {reply, Reply, NewState} |
%%                                          {stop, Reason, NewProc, NewState} |
%%                                          {stop, Reason, NewState} |
%%                                          {NewProc, NewState} |
%%                                          NewState.
%%
handle_interaction({M, F, Argv},
                   #proc{id=Id}, Sh=#sh{rpc_enabled=true}) ->
    {reply, rpc:call(Id, M, F, Argv), Sh};
handle_interaction(_Data, _Proc, Sh=#sh{port=detached}) ->
    {stop, {error, detached}, Sh};
handle_interaction(Data, _Proc, Sh=#sh{port=Port}) ->
    port_command(Port, Data, [nosuspend]),
    {reply, ok, Sh}.

%% @doc handles a status request from the server.
%% handle_status(Proc, State) -> {reply, Reply, NewProc, NewState} |
%%                               {reply, Reply, NewState} |
%%                               {stop, NewProc, NewState}.
handle_status(Proc, Sh=#sh{rpc_enabled=true}) ->
    {reply, systest_proc:status_check(Proc#proc.id), Sh};
handle_status(_Proc, Sh=#sh{rpc_enabled=false, state=ProgramState}) ->
    %% TODO: this is wrong - we should spawn and use gen_server:reply
    %%       especially in light of the potential delay in running ./stop
    case ProgramState of
        running -> {reply, up, Sh};
        stopped -> {reply, {down, stopped}, Sh};
        Other   -> {reply, Other, Sh}
    end.

%% @doc handles a kill instruction from the server.
%% handle_kill(Proc, State) -> {NewProc, NewState} |
%%                             {stop, NewProc, NewState} |
%%                             NewState.
handle_kill(#proc{os_pid=OsPid},
            Sh=#sh{detached=true, state=running}) ->
    systest:sigkill(OsPid),
    Sh#sh{state=killed};
handle_kill(_Proc, Sh=#sh{id=Id, port=Port, detached=false, state=running}) ->
    log({framework, Id},
        "kill instruction received - terminating port ~p~n", [Port]),
    Port ! {self(), close},
    Sh#sh{state=killed}.

%% @doc handles a stop instruction from the server.
%% handle_stop(Proc, State) -> {NewProc, NewProc} |
%%                             {stop, NewProc, NewState} |
%%                             {rpc_stop, {M,F,A}, NewState} |
%%                             NewState.
handle_stop(Proc, Sh=#sh{stop_command=SC}) when is_record(SC, 'exec') ->
    log(framework, "running shutdown hooks for ~p~n",
        [systest_proc:get(id, Proc)]),
    run_shutdown_hook(SC, Sh);
%% TODO: could this be core proc behaviour?
handle_stop(_Proc, Sh=#sh{stop_command=Shutdown, rpc_enabled=true}) ->
    %% TODO: this rpc/call logic should move into systest_proc
    Halt = case Shutdown of
               default -> {init, stop, []};
               Custom  -> Custom
           end,
    % apply(rpc, call, [Proc#proc.id|tuple_to_list(Halt)]),
    {rpc_stop, Halt, Sh#sh{state=stopped}}.
%% TODO: when rpc_enabled=false and shutdown is undefined???

%% @doc handles generic messages from the server.
%% handle_msg(Msg, Proc, State) -> {reply, Reply, NewProc, NewState} |
%%                                 {reply, Reply, NewState} |
%%                                 {stop, Reason, NewProc, NewState} |
%%                                 {stop, Reason, NewState} |
%%                                 {NewProc, NewState} |
%%                                 NewState.
handle_msg(sigkill, #proc{os_pid=OsPid}, Sh=#sh{state=running}) ->
    systest:sigkill(OsPid),
    Sh#sh{state=killed};
handle_msg({Port, {data, {_, Line}}}, _Proc,
            Sh=#sh{port=Port, log=LogFd}) ->
    io:format(LogFd, "~s~n", [Line]),
    Sh;
handle_msg({Port, {exit_status, 0}}, _Proc,
            Sh=#sh{id=Id, port=Port, start_command=#exec{command=Cmd}}) ->
    log({framework, Id}, "program ~s exited normally (status 0)~n", [Cmd]),
    {stop, normal, Sh#sh{state=stopped}};
handle_msg({Port, {exit_status, Exit}=Rc}, Proc,
             Sh=#sh{id=Id, port=Port, state=State}) ->
    log({framework, Id},
        "os process ~p shut down with error/status code ~p~n",
        [Proc#proc.id, Exit]),
    ShutdownType = case ?IS_DYING(State) of
                       true  -> normal;
                       false -> Rc
                   end,
    {stop, ShutdownType, Sh};
handle_msg({Port, closed}, Proc,
            Sh=#sh{id=Id, port=Port,
                   state=State, detached=false}) when ?IS_DYING(State) ->
    log({framework, Id}, "~p (attached) closed~n", [Port]),
    case Sh#sh.rpc_enabled of
        true ->
            %% to account for a potential timing issue when the calling test
            %% execution process is sitting in `kill_and_wait` - we force a
            %% call to net_adm:ping/1, which gives the net_kernel more time to
            %% to try and its knickers out of a twist before proceeding....
            Id = systest_proc:get(id, Proc),
            systest_proc:status_check(Id);
        false ->
            ok
    end,
    {stop, normal, Sh};
handle_msg({Port, closed}, _Proc, Sh=#sh{id=Id, port=Port}) ->
    log({framework, Id}, "~p closed~n", [Port]),
    {stop, {port_closed, Port}, Sh};
handle_msg({'EXIT', Pid, {ok, StopAcc}}, _Proc,
            Sh=#sh{shutdown_port=SPort,
                   detached=Detached,
                   state=State,
                   log=Fd,
                   id=Id}) when Pid == SPort andalso
                                ?IS_DYING(State) ->
    log({framework, Id}, "termination Port completed ok~n"),
    io:format(Fd, "Halt Log ==============~n~s~n", [StopAcc]),
    case Detached of
        true  -> {stop, normal, Sh};
        false -> Sh
    end;
handle_msg({'EXIT', Pid, {error, Rc, StopAcc}},
           _Proc, Sh=#sh{id=Id,
                         shutdown_port=SPort,
                         log=Fd}) when Pid == SPort ->
    log({framework, Id},
        "termination Port stopped abnormally (status ~p)~n", [Rc]),
    io:format(Fd, "Halt Log ==============~n~s~n", [StopAcc]),
    {stop, termination_port_error, Sh};
handle_msg(Info, _Proc, Sh=#sh{id=Id, state=St, port=P, shutdown_port=SP}) ->
    log({framework, Id},
        "Ignoring Info Message:  ~p~n"
        "State:                  ~p~n"
        "Port:                   ~p~n"
        "Termination Port:       ~p~n",
        [Info, St, P, SP]),
    Sh.

%% @doc gives the handler a chance to clean up prior to being fully stopped.
terminate(Reason, _Proc, #sh{port=Port, id=Id, log=Fd}) ->
    log({framework, Id}, "terminating due to ~p~n", [Reason]),
    %% TODO: verify that we're not *leaking* ports if we fail to close them
    case Fd of
        user -> ok;
        _    -> catch(file:close(Fd))
    end,
    case Port of
        detached -> ok;
        _Port    -> catch(port_close(Port)),
                    ok
    end.

%%
%% Private API
%%

on_startup(Scope, Id, Port, Detached, RpcEnabled, Env, Config, StartFun) ->
    %% we do the initial receive stuff up-front
    %% just to avoid any initial ordering problems...

    Startup = ?CONFIG(startup, Config, []),
    LogEnabled = ?CONFIG(log_enabled, Startup, true),
    {LogName, LogFd} = case LogEnabled of
                           true ->
                               LogFile = log_file("-stdio.log", Scope,
                                                  Id, Env, Config),
                               {ok, Fd2} = file:open(LogFile, [write]),
                               {LogFile, Fd2};
                           false ->
                               {"console", user}
                       end,

    log({framework, Id}, "Reading OS process id from ~p~n", [Port]),
    log({framework, Id}, "RPC Enabled: ~p~n", [RpcEnabled]),
    log({framework, Id}, "StdIO Log: ~s~n", [LogName]),

    %% we make a hidden connection by default, so as to protect
    %% any trace handling that is going on, and to avoid 'messing up'
    %% any assumptions that a SUT might make about the expected state
    %% returned from erlang:nodes/0
    if RpcEnabled == true -> net_kernel:hidden_connect_node(Id);
       RpcEnabled /= true -> ok
    end,  
    case read_pid(Id, Port, Detached, RpcEnabled, LogFd) of
        {error, {stopped, Rc}} ->
            {stop, {launch_failure, Rc}};
        {error, Reason} ->
            {stop, {launch_failure, Reason}};
        {Port2, Pid, LogFd} ->
            StartFun(Port2, Pid, LogFd)
    end.

log_file(Suffix, Scope, Id, Env, Config) ->
    log_to(Suffix, Scope, Id,
           ?CONFIG(log_dir, Env, systest_env:default_log_dir(Config))).

log_to(Suffix, Scope, Id, Dir) ->
    filename:join(Dir, logfile(Scope, Id) ++ Suffix).

make_exec(FG, Detached, RpcEnabled, Config) ->
    FlagsGroup = atom_to_list(FG),
    %% TODO: provide a 'get_multi' version that avoids traversing repeatedly
    Cmd = systest_config:eval("flags." ++ FlagsGroup ++ ".program", Config,
                    [{callback, {proc, fun systest_proc:get/2}},
                     {return, value}]),
    Env = case ?ENCONFIG("flags." ++ FlagsGroup ++ ".environment", Config) of
              not_found -> [];
              undefined -> [];
              Environ   -> Environ
          end,
    Args = case ?ENCONFIG("flags." ++ FlagsGroup ++ ".args", Config) of
               not_found -> [];
               undefined -> [];
               Argv      -> Argv
           end,
    RunEnv = [{env, Env}],
    ExecutableCommand = maybe_patch_command(Cmd, RunEnv, Args,
                                            Detached, RpcEnabled),
    #exec{command=ExecutableCommand, argv=Args, environment=Env}.

stop_flags(Flags, ShutdownSpec, Detached, RpcEnabled, Config) ->
    case ?CONFIG(stop, Flags, undefined) of
        undefined ->
            case RpcEnabled of
                %% eh!? this needs to be a {stop, ReturnVal}
                false -> throw(shutdown_spec_missing);
                true  -> ShutdownSpec
            end;
        {call, M, F, Argv} ->
            {M, F, Argv};
        _Spec ->
            make_exec(stop, Detached, RpcEnabled, Config)
    end.


open_port(#exec{command=ExecutableCommand,
                argv=Args, environment=Env}, Detached) ->
    RunEnv = [{env, Env}],
    LaunchOpts = [exit_status, hide, stderr_to_stdout,
                  use_stdio, {line, 16384}] ++ RunEnv,
    log(framework, 
        "Spawning executable [command = \"~s\", detached = ~p, args = ~p]~n",
        [ExecutableCommand, Detached, Args]),
    case Detached of
        false -> erlang:open_port({spawn_executable, ExecutableCommand},
                                  [{args, Args}|LaunchOpts]);
        true  -> erlang:open_port({spawn, ExecutableCommand}, LaunchOpts)
    end.

run_shutdown_hook(Exec, Sh=#sh{detached=Detached}) ->
    Pid= spawn_link(fun() ->
                        Port = open_port(Exec, Detached),
                        exit(shutdown_loop(Port, []))
                    end),
    Sh#sh{shutdown_port=Pid, state=stopped}.

%% port handling

shutdown_loop(Port, Acc) ->
    receive
        {Port, {exit_status, 0}}    -> {ok, output(Acc)};
        {Port, {exit_status, Rc}}   -> {error, Rc, output(Acc)};
        {Port, {data, {eol, Line}}} -> shutdown_loop(Port, [Line|Acc]);
        {Port, {data, {eol, []}}}   -> shutdown_loop(Port, Acc);
        {Port, {data, Data}}        -> shutdown_loop(Port,
                                          [io_lib:format("~p~n", [Data])|Acc])
    end.

output(Items) ->
    string:join(Items, "\n").

read_pid(ProcId, Port, Detached, RpcEnabled, Fd) ->
    case RpcEnabled of
        true ->
            case rpc:call(ProcId, os, getpid, []) of
                {badrpc, _Reason} ->
                    receive
                        {Port, {exit_status, 0}} ->
                            case Detached of
                                %% NB: with detached procs, the 'launcher' will
                                %% exit leaving the proc up and running, so we
                                %% now need to sit in a loop until we can rpc
                                true  -> read_pid(ProcId, Port,
                                                  Detached, RpcEnabled, Fd);
                                false -> {error, no_pid}
                            end;
                        {Port, {exit_status, Rc}} ->
                            {error, {stopped, Rc}};
                        {Port, {data, {_, Line}}} ->
                            io:format(Fd, "[~p] ~s~n", [ProcId, Line]),
                            %% NB: the 'launch' process has sent us a pid, but
                            %% that's meaningless for detached procs until we
                            %% can successfully rpc to get the actual pid.
                            case Detached of
                                true  -> wait_for_up(ProcId);
                                false -> ok
                            end,
                            read_pid(ProcId, Port, Detached, RpcEnabled, Fd);
                        Other ->
                            io:format(Fd, "[~p] ~p~n", [ProcId, Other]),
                            read_pid(ProcId, Port, Detached, RpcEnabled, Fd)
                    after 5000 ->
                        log({framework, ProcId},
                            "timeout waiting for os pid... re-trying~n", []),
                        read_pid(ProcId, Port, Detached, RpcEnabled, Fd)
                    end;
                Pid ->
                    case Detached of
                        false -> {Port, Pid, Fd};
                        true  -> {detached, Pid, Fd}
                    end
            end;
        false ->
            %% NB: detached + rpc_disabled is currently disallowed, so we don't
            %% cater for {detached, Pid} here at all.
            receive
                {Port, {data, {eol, Pid}}} -> {Port, Pid, Fd};
                {Port, {exit_status, Rc}}  -> {error, {stopped, Rc}}
            end
    end.

wait_for_up(NodeId) ->
    case net_kernel:hidden_connect_node(NodeId) of
        true    -> ok;
        _       -> erlang:yield(), wait_for_up(NodeId)
    end.

%% command processing

check_command_mode(true, false) ->
    %% TODO: think about if/how we can relax this rule....
    {error, {detached, no_rpc}};
check_command_mode(_, _) ->
    ok.

maybe_patch_command(Cmd, _, _, false, true) ->
    Cmd;
maybe_patch_command(Cmd, Env, Args, Detached, RpcEnabled) when Detached orelse
                                                               RpcEnabled ->
    %% TODO: reconsider this, as I'm not convinced it behaves properly....
    case os:type() of
        {win32, _} ->
            %% TODO: the argv conversion thing here....
            "cmd /q /c " ++ lists:foldl(fun({Key, Value}, Acc) ->
                                        expand_env_variable(Acc, Key, Value)
                                        end, Cmd, Env);
        _ ->
            Exec = string:join([Cmd|Args], " "),
            "/usr/bin/env sh -c \"echo $$; exec " ++ Exec ++ "\""
    end.

%%
%% Given env. variable FOO we want to expand all references to
%% it in InStr. References can have two forms: $FOO and ${FOO}
%% The end of form $FOO is delimited with whitespace or eol
%%
expand_env_variable(InStr, VarName, RawVarValue) ->
    case string:chr(InStr, $$) of
        0 ->
            %% No variables to expand
            InStr;
        _ ->
            VarValue = re:replace(RawVarValue, "\\\\", "\\\\\\\\", [global]),
            %% Use a regex to match/replace:
            %% Given variable "FOO": match $FOO\s | $FOOeol | ${FOO}
            RegEx = io_lib:format("\\\$(~s(\\s|$)|{~s})", [VarName, VarName]),
            ReOpts = [global, {return, list}],
            re:replace(InStr, RegEx, [VarValue, "\\2"], ReOpts)
    end.

%% proc configuration/setup

logfile(Scope, Id) ->
    atom_to_list(Scope) ++ "-" ++ atom_to_list(Id).

