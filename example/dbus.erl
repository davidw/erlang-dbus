-module(dbus).

-import(dberl.proxy).
-import(dberl.bus).
-import(dberl.bus_reg).

-behaviour(gen_server).

-include("dbus.hrl").

%% gen_server callbacks
-export([
	 init/1,
	 code_change/3,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2
	]).

%% api
-export([
	 start_link/0
	]).

-define(SERVER, ?MODULE).
-define(HOST, "localhost").
-define(PORT, 1236).

-record(state, {
	  bus,
	  bus_obj
	 }).

-export([make/0, test/0, run_test/1]).

make() ->
    Modules = [
	       "dbus",
	       "hello",
	       "hello_app",
	       "hello_sup"
	      ],

    Prefix = "/home/mikael/svn/dberl/example/",
    make_modules(Prefix, Modules).

make_modules(Prefix, Modules) ->
    Files = lists:map(fun(File) -> Prefix ++ File end, Modules),

    make:files(Files,
	       [
		load,
		{i, "/home/mikael/svn/dberl/src"},
		{i, "/usr/lib/erlang/lib/xmerl-1.0.5/include"},
		{outdir, Prefix}
	       ]).


test() ->
    {ok, Pid} = start_link(),
    run_test(Pid).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [?HOST, ?PORT], []).

run_test(Pid) ->
    gen_server:call(Pid, run_test).

%%
%% gen_server callbacks
%%
init([Host, Port]) ->
    self() ! {setup, Host, Port},
    {ok, #state{}}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_call(run_test, _From, State) ->
    do_test(State),
    {reply, ok, State};

handle_call(Request, _From, State) ->
    error_logger:error_msg("Unhandled call in ~p: ~p~n", [?MODULE, Request]),
    {reply, ok, State}.


handle_cast(Request, State) ->
    error_logger:error_msg("Unhandled cast in ~p: ~p~n", [?MODULE, Request]),
    {noreply, State}.


handle_info({setup, Host, Port}, State) ->
    {ok, Bus} = bus_reg:get_bus(Host, Port),
    true = link(Bus),
    ok = bus:wait_ready(Bus),
    io:format("Ready~n"),

    {ok, BusObj} = bus:get_object(Bus, 'org.freedesktop.DBus', '/'),
    true = link(BusObj),
    io:format("BusObj: ~p~n", [BusObj]),

    {noreply, State#state{bus=Bus,
			  bus_obj=BusObj
			 }};
handle_info(Info, State) ->
    error_logger:error_msg("Unhandled info in ~p: ~p~n", [?MODULE, Info]),
    {noreply, State}.


terminate(_Reason, _State) ->
    terminated.


do_test(State) ->
    Bus = State#state.bus,

    {ok, RbShellObj} = bus:get_object(Bus, 'org.gnome.Rhythmbox', '/org/gnome/Rhythmbox/Shell'),
    {ok, RbShell} = proxy:interface(RbShellObj, 'org.gnome.Rhythmbox.Shell'),
    {ok, RbPlayerObj} = bus:get_object(Bus, 'org.gnome.Rhythmbox', '/org/gnome/Rhythmbox/Player'),
    {ok, RbPlayer} = proxy:interface(RbPlayerObj, 'org.gnome.Rhythmbox.Player'),
    {ok, Uri} = proxy:call(RbPlayer, 'getPlayingUri'),
    {ok, Song} = proxy:call(RbShell, 'getSongProperties', [Uri]),
    io:format("Song: ~p~n~p~n", [Uri, Song]),

%%     io:format("manager: ~p~n", [proxy:call(RbShell, 'getPlaylistManager')]),
%%     io:format("player: ~p~n", [proxy:call(RbShell, 'getPlayer')]),

    {ok, Remote_object} = bus:get_object(Bus, 'org.designfu.SampleService', '/SomeObject'),
    io:format("Remote_object: ~p~n", [Remote_object]),
    {ok, Iface} = proxy:interface(Remote_object, 'org.designfu.SampleInterface'),
    ok = proxy:connect_signal(Iface, 'OnClick', mytag),
%%     Var = #variant{type=string, value="Hello from Erlang!"},
%%      Var = #variant{type={array, string}, value=["Hello", "from", "Erlang!"]},
%%     Var = <<"Hello from Erlang">>,
%%     Var = #variant{type={struct, [int16, string]}, value=[17, "Hello from Erlang!"]},
    Var = #variant{type={struct, [int16, string]}, value={17, "Hello from Erlang!"}},
    {ok, Reply1} = proxy:call(Iface, 'HelloWorld', [Var]),
    io:format("HelloWorld 1: ~p~n", [Reply1]),

    Var1 = #variant{type={struct, [int16, string]}, value={17, "Hello from Erlang no 2!"}},
    {ok, Reply2} = proxy:call(Iface, 'HelloWorld', [Var1]),
    io:format("HelloWorld 2: ~p~n", [Reply2]),
%%     ok = proxy:stop(Remote_object),
%%     ok = bus:stop(Bus),

%%     {ok, PeerIface} = proxy:interface(BusObj, 'org.freedesktop.DBus.Peer'),
%%     proxy:call(PeerIface, 'Ping'),
    ok.
