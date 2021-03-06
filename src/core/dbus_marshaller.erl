%%
%% @copyright 2006-2007 Mikael Magnusson
%% @copyright 2014 Jean Parpaillon
%%
%% @author Mikael Magnusson <mikma@users.sourceforge.net>
%% @author Jean Parpaillon <jean.parpaillon@free.fr>
%% @doc (un)marshalling
%%
-module(dbus_marshaller).
-compile([{parse_transform, lager_transform}]).

-include("dbus.hrl").

%% api
-export([
	 marshal_message/1,
	 marshal_signature/1,
	 marshal_list/2,
	 unmarshal_data/1,
	 unmarshal_signature/1
	]).

-define(HEADER_SIGNATURE, [byte, byte, byte, byte, uint32, uint32, {array, {struct, [byte, variant]}}]).

%%%
%%% API
%%%
-spec marshal_message(dbus_message()) -> iolist().
marshal_message(#dbus_message{header=#dbus_header{serial=0}}=_Msg) ->
    throw({error, invalid_serial});
marshal_message(#dbus_message{header=#dbus_header{type=Type, flags=Flags, serial=S, fields=Fields}, 
			      body= <<>>}=_Msg) ->
    marshal_header([$l, Type, Flags, ?DBUS_VERSION_MAJOR, 0, S, Fields]);
marshal_message(#dbus_message{header=#dbus_header{type=Type, flags=Flags, serial=S, fields=Fields, size=Size}, 
			      body=Body}=_Msg) ->
    [ marshal_header([$l, Type, Flags, ?DBUS_VERSION_MAJOR, Size, S, Fields]), Body ].

-spec marshal_signature(dbus_signature()) -> iolist().
marshal_signature(byte)        ->   "y";
marshal_signature(boolean)     ->   "b";
marshal_signature(int16)       ->   "n";
marshal_signature(uint16)      ->   "q";
marshal_signature(int32)       ->   "i";
marshal_signature(uint32)      ->   "u";
marshal_signature(int64)       ->   "x";
marshal_signature(uint64)      ->   "t";
marshal_signature(double)      ->   "d";
marshal_signature(string)      ->   "s";
marshal_signature(object_path) ->   "o";
marshal_signature(signature)   ->   "g";
marshal_signature({array, Type}) ->
    [$a, marshal_signature(Type)];
marshal_signature({struct, SubTypes}) ->
    ["(", marshal_struct_signature(SubTypes, []), ")"];
marshal_signature(variant) ->
    "v";
marshal_signature({dict, KeyType, ValueType}) ->
    KeySig = marshal_signature(KeyType),
    ValueSig = marshal_signature(ValueType),
    ["a{", KeySig, ValueSig, "}"];
marshal_signature([]) ->
    "";
marshal_signature([Type|R]) ->
    [marshal_signature(Type), marshal_signature(R)].


-spec marshal_list(dbus_signature(), term()) -> iolist().
marshal_list(Types, Value) ->
    marshal_list(Types, Value, 0, []).


-spec unmarshal_data(binary()) -> {ok, Msgs :: [dbus_message()], Rest :: binary()} | more.
unmarshal_data(Data) ->
    unmarshal_data(Data, []).


-spec unmarshal_signature(binary()) -> {ok, dbus_signature()} | more.
unmarshal_signature(<<>>) -> 
    {ok, []};

unmarshal_signature(Bin) when is_binary(Bin) ->
    case unmarshal_signature(Bin, []) of
	{ok, Signature, <<>>} -> {ok, Signature};
	more -> more
    end.

%%%
%%% Priv marshalling
%%%
marshal_header(Header) when is_list(Header) ->
    {Value, Pos} = marshal_list(?HEADER_SIGNATURE, Header),
    case pad(8, Pos) of
	0 -> Value;
	Pad -> [Value, <<0:Pad>>]
    end.


marshal_list([], [], Pos, Res) ->
    {Res, Pos};
marshal_list([Type | T], [Value | V], Pos, Res) ->
    {Res1, Pos1} = marshal(Type, Value, Pos),
    marshal_list(T, V, Pos1, [Res, Res1]).

marshal(byte, Value, Pos) ->
    marshal_uint(1, Value, Pos);

marshal(boolean, Value, Pos) ->
    Int =
	    case Value of
	        true -> 1;
	        false -> 0
	    end,
    marshal(uint32, Int, Pos);

marshal(int16, Value, Pos) ->
    marshal_int(2, Value, Pos);

marshal(uint16, Value, Pos) ->
    marshal_uint(2, Value, Pos);

marshal(int32, Value, Pos) ->
    marshal_int(4, Value, Pos);

marshal(uint32, Value, Pos) ->
    marshal_uint(4, Value, Pos);

marshal(int64, Value, Pos) ->
    marshal_int(8, Value, Pos);

marshal(uint64, Value, Pos) ->
    marshal_uint(8, Value, Pos);

marshal(double, Value, Pos) when is_float(Value) ->
    Pad = pad(8, Pos),
    {<< 0:Pad, Value:64/native-float >>, Pos + Pad div 8+ 8};

marshal(string, Value, Pos) when is_atom(Value) ->
    marshal(string, atom_to_binary(Value, utf8), Pos);

marshal(string, Value, Pos) when is_binary(Value) ->
    marshal_string(uint32, Value, Pos);
    
marshal(string, Value, Pos) when is_list(Value) ->
    marshal(string, list_to_binary(Value), Pos);

marshal(object_path, Value, Pos) ->
    marshal(string, Value, Pos);

marshal(signature, Value, Pos) ->
    marshal_string(byte, Value, Pos);

marshal({array, byte}=Type, Value, Pos) when is_binary(Value) ->
    marshal(Type, binary_to_list(Value), Pos);

marshal({array, SubType}, Value, Pos) when is_list(Value) ->
    Pad = pad(uint32, Pos),
    Pos0 = Pos + Pad div 8,
    Pos1 = Pos0 + 4,
    Pad1 = pad(SubType, Pos1),
    Pos1b = Pos1 + Pad1 div 8,
    {Value2, Pos2} = marshal_array(SubType, Value, Pos1b),
    Length = Pos2 - Pos1b,
    {Value1, Pos1} = marshal(uint32, Length, Pos0),
    {[<<0:Pad>>, Value1, <<0:Pad1>>, Value2], Pos2};

marshal({struct, _SubTypes}=Type, Value, Pos) when is_tuple(Value) ->
    marshal(Type, tuple_to_list(Value), Pos);

marshal({struct, SubTypes}, Value, Pos) when is_list(Value) ->
    marshal_struct(SubTypes, Value, Pos);

marshal({dict, KeyType, ValueType}, Value, Pos) ->
    marshal_dict(KeyType, ValueType, Value, Pos);

marshal(variant, Value, Pos) when is_binary(Value) ->
    marshal_variant({array, byte}, Value, Pos);

marshal(variant, #dbus_variant{type=Type, value=Value}, Pos) ->
    marshal_variant(Type, Value, Pos);

marshal(variant, true=Value, Pos) ->
    marshal_variant(boolean, Value, Pos);

marshal(variant, false=Value, Pos) ->
    marshal_variant(boolean, Value, Pos);

marshal(variant, Value, Pos) when is_integer(Value), Value < 0 ->
    marshal_int_variant(Value, Pos);

marshal(variant, Value, Pos) when is_integer(Value), Value >= 0 ->
    marshal_uint_variant(Value, Pos);

marshal(variant, Value, Pos) when is_tuple(Value) ->
    Type = infer_type(Value),
    marshal_variant(Type, Value, Pos);

marshal(variant, Value, Pos) when is_list(Value) ->
    marshal(variant, list_to_binary(Value), Pos).

infer_type(Value) when is_binary(Value)->
    {array, byte};
infer_type(true) ->
    boolean;
infer_type(false) ->
    boolean;
infer_type(Value) when is_integer(Value), Value < 0 ->
    infer_int(Value);
infer_type(Value) when is_integer(Value), Value >= 0 ->
    infer_uint(Value);
infer_type(Value) when is_tuple(Value) ->
    infer_struct(tuple_to_list(Value));
infer_type(Value) when is_atom(Value)->
    string;
infer_type(Value) when is_list(Value) ->
    string.


infer_struct(Values) ->
    {struct, infer_struct(Values, [])}.

infer_struct([], Res) ->
    Res;
infer_struct([Value|R], Res) ->
    infer_struct(R, [Res, infer_type(Value)]).

infer_int(Value) when Value >= -32768 ->
    int16;
infer_int(Value) when Value >= -4294967296 ->
    int32;
infer_int(_Value) ->
    int64.

infer_uint(Value) when Value < 32768 ->
    uint16;
infer_uint(Value) when Value < 4294967296 ->
    uint32;
infer_uint(_Value) ->
    uint64.


marshal_int_variant(Value, Pos) when Value >= -32768 ->
    marshal_variant(int16, Value, Pos);
marshal_int_variant(Value, Pos) when Value >= -4294967296 ->
    marshal_variant(int32, Value, Pos);
marshal_int_variant(Value, Pos) ->
    marshal_variant(int64, Value, Pos).

marshal_uint_variant(Value, Pos) when Value < 32768 ->
    marshal_variant(uint16, Value, Pos);
marshal_uint_variant(Value, Pos) when Value < 4294967296 ->
    marshal_variant(uint32, Value, Pos);
marshal_uint_variant(Value, Pos) ->
    marshal_variant(uint64, Value, Pos).

marshal_variant(Type, Value, Pos) ->
    {Value1, Pos1} = marshal(signature, marshal_signature(Type), Pos),
    {Value2, Pos2} = marshal(Type, Value, Pos1),
    {[Value1, Value2], Pos2}.


marshal_uint(Len, Value, Pos) when is_integer(Value) ->
    Pad = pad(Len, Pos),
    {<< 0:Pad, Value:(Len*8)/native-unsigned >>, Pos + Pad div 8 + Len}.

marshal_int(Len, Value, Pos) when is_integer(Value) ->
    Pad = pad(Len, Pos),
    {<< 0:Pad, Value:(Len*8)/native-signed >>, Pos + Pad div 8 + Len}.


marshal_string(LenType, Value, Pos) when is_list(Value) ->
    marshal_string(LenType, list_to_binary(Value), Pos);

marshal_string(LenType, Value, Pos) when is_binary(Value) ->
    Length = byte_size(Value),
    {Value1, Pos1} = marshal(LenType, Length, Pos),
    {[Value1, Value, 0], Pos1 + Length + 1}.


marshal_array(SubType, Array, Pos) ->
    marshal_array(SubType, Array, Pos, []).

marshal_array(_SubType, [], Pos, Res) ->
    {Res, Pos};
marshal_array(SubType, [Value|R], Pos, Res) ->
    {Value1, Pos1} = marshal(SubType, Value, Pos),
    marshal_array(SubType, R, Pos1, [Res, Value1]).


marshal_dict(KeyType, ValueType, Value, Pos) when is_tuple(Value) ->
    Array = dict:to_list(Value),
    marshal_dict(KeyType, ValueType, Array, Pos);

marshal_dict(KeyType, ValueType, Value, Pos) when is_list(Value) ->
    marshal({array, {struct, [KeyType, ValueType]}}, Value, Pos).


marshal_struct(SubTypes, Values, Pos) ->
    Pad = pad(8, Pos),
    {Values1, Pos1} = marshal_struct(SubTypes, Values, Pos + Pad div 8, []),
    if
	    Pad == 0 ->
	        {Values1, Pos1};
	    Pad > 0 ->
	        {[<< 0:Pad >>, Values1], Pos1}
    end.

marshal_struct([], [], Pos, Res) ->
    {Res, Pos};
marshal_struct([SubType|R], [Value|V], Pos, Res) ->
    {Value1, Pos1} = marshal(SubType, Value, Pos),
    marshal_struct(R, V, Pos1, [Res, Value1]).



marshal_struct_signature([], Res) ->
    Res;
marshal_struct_signature([SubType|R], Res) ->
    marshal_struct_signature(R, [Res, marshal_signature(SubType)]).

%%%
%%% Private unmarshaling
%%%
unmarshal_data(<<>>, []) ->
    more;

unmarshal_data(<<>>, Acc) ->
    {ok, lists:reverse(Acc), <<>>};

unmarshal_data(Data, Acc) ->
    try unmarshal_message(Data) of
	{ok, #dbus_message{}=Msg, Rest} -> 
	    unmarshal_data(Rest, [Msg | Acc]);
	more when [] =:= Acc ->
	    more;
	more ->
	    {ok, lists:reverse(Acc), Data};
	_ ->
	    lager:error("Error parsing data~n", []),
	    throw({error, dbus_parse_error})
    catch
	{'EXIT', Err} -> 
	    throw({error, {dbus_parse_error, Err}})
    end.


unmarshal_message(<<>>) ->
    more;

unmarshal_message(Data) when is_binary(Data) ->
    case unmarshal_header(Data) of
	more -> more;
	{ok, #dbus_header{type=MsgType}=Header, BodyBin, Rest} ->
	    case dbus_message:find_field(?FIELD_SIGNATURE, Header) of
		undefined ->
		    case BodyBin of
			<<>> -> {ok, #dbus_message{header=Header, body= <<>>}, Rest};
			_ -> throw({error, body_parse_error})
		    end;
		Signature ->
		    case unmarshal_body(MsgType, Signature, BodyBin) of
			{ok, Body} -> {ok, #dbus_message{header=Header, body=Body}, Rest};
			more -> more;
			{error, Err} -> throw({error, Err})
		    end
	    end
    end.


unmarshal_body(?TYPE_SIGNAL, SigBin, BodyBin) ->
    case unmarshal_signature(SigBin) of
	{ok, Sig} ->
	    case unmarshal_list(Sig, BodyBin) of
		more -> more;
		{ok, Body, <<>>, _Pos} -> {ok, Body};
		{ok, _Body, _, _} -> {error, body_parse_error}
	    end;
	more -> more
    end;

unmarshal_body(?TYPE_INVALID, _, _) ->
    {ok, <<>>};

unmarshal_body(_Type, SigBin, BodyBin) ->
    case unmarshal_single_type(SigBin) of
	{ok, Type} ->
	    case unmarshal(Type, BodyBin, 0) of
		more -> more;
		{ok, Body, <<>>, _} -> {ok, Body};
		{ok, _Body, _, _} -> {error, body_parse_error}
	    end;
	more -> more
    end.


unmarshal_header(Bin) ->
    case unmarshal_list(?HEADER_SIGNATURE, Bin) of
	more -> more;
	{ok, [$l, _, _, ?DBUS_VERSION_MAJOR, Size, _, _], Rest, _} when byte_size(Rest) < Size  ->
	    more;
	{ok, [$l, Type, Flags, ?DBUS_VERSION_MAJOR, Size, Serial, Fields], Rest, Pos} ->
	    Header = #dbus_header{type=Type, flags=Flags, serial=Serial, size=Size, 
				  fields=unmarshal_known_fields(Fields)},
	    Pad = pad(8, Pos),
	    <<0:Pad, Body:Size/binary, Rest2/binary>> = Rest,
	    {ok, Header, Body, Rest2};
	{ok, Header, _, _} -> 
	    lager:debug("Bad message header: ~p~n", [Header]),
	    throw({error, bad_header})
    end.


unmarshal_known_fields(Fields) ->
    unmarshal_known_fields(Fields, []).


unmarshal_known_fields([], Acc) ->
    Acc;

unmarshal_known_fields([{?FIELD_INTERFACE, #dbus_variant{value=Val}=F} | Fields], Acc) ->
    Val2 = dbus_names:bin_to_iface(Val),
    unmarshal_known_fields(Fields, [{?FIELD_INTERFACE, F#dbus_variant{value=Val2}} | Acc]);

unmarshal_known_fields([{?FIELD_MEMBER, #dbus_variant{value=Val}=F} | Fields], Acc) ->
    Val2 = dbus_names:bin_to_member(Val),
    unmarshal_known_fields(Fields, [{?FIELD_MEMBER, F#dbus_variant{value=Val2}} | Acc]);

unmarshal_known_fields([{?FIELD_ERROR_NAME, #dbus_variant{value=Val}=F} | Fields], Acc) ->
    Val2 = dbus_names:bin_to_error(Val),
    unmarshal_known_fields(Fields, [{?FIELD_ERROR_NAME, F#dbus_variant{value=Val2}} | Acc]);

unmarshal_known_fields([ Field | Fields ], Acc) ->
    unmarshal_known_fields(Fields, [Field | Acc]).


unmarshal_single_type(<<>>) ->
    empty;

unmarshal_single_type(Bin) when is_binary(Bin) ->
    case unmarshal_signature(Bin, []) of
	{ok, [Type], <<>>} -> {ok, Type};
	more -> more
    end.

unmarshal(_, <<>>, _) ->
    more;

unmarshal(byte, Data, Pos) ->
    << Value:8, Data1/binary >> = Data,
    {ok, Value, Data1, Pos + 1};

unmarshal(boolean, Data, Pos) ->
    case unmarshal(uint32, Data, Pos) of
	more -> more;
	{ok, 1, Data1, Pos1} ->
	    {ok, true, Data1, Pos1};
	{ok, 0, Data1, Pos1} ->
	    {ok, false, Data1, Pos1};
	{ok, Else, _, _} ->
	    throw({error, {parse_error, boolean, Else}})
    end;

unmarshal(uint16, Data, Pos) ->
    unmarshal_uint(2, Data, Pos);

unmarshal(uint32, Data, Pos) ->
    unmarshal_uint(4, Data, Pos);

unmarshal(uint64, Data, Pos) ->
    unmarshal_uint(8, Data, Pos);

unmarshal(int16, Data, Pos) ->
    unmarshal_int(2, Data, Pos);

unmarshal(int32, Data, Pos) ->
    unmarshal_int(4, Data, Pos);

unmarshal(int64, Data, Pos) ->
    unmarshal_int(8, Data, Pos);

unmarshal(double, Data, _) when byte_size(Data) < 8 ->
    more;

unmarshal(double, Data, Pos) ->
    Pad = pad(8, Pos),
    << 0:Pad, Value:64/native-float, Data1/binary >> = Data,
    Pos1 = Pos + Pad div 8 + 8,
    {ok, Value, Data1, Pos1};

unmarshal(signature, Data, Pos) ->
    unmarshal_string(byte, Data, Pos);

unmarshal(string, Data, Pos) ->
    unmarshal_string(uint32, Data, Pos);

unmarshal(object_path, Data, Pos) ->
    unmarshal_string(uint32, Data, Pos);

unmarshal({array, SubType}, Data, Pos) ->
    case unmarshal(uint32, Data, Pos) of
	more -> 
	    more;
	{ok, Length, Rest, NewPos} ->
	    unmarshal_array(SubType, Length, Rest, NewPos)
    end;

unmarshal({struct, _}, Data, _) when byte_size(Data) < 8 ->
    more;

unmarshal({struct, SubTypes}, Data, Pos) ->
    Pad = pad(8, Pos),
    << 0:Pad, Data1/binary >> = Data,
    Pos1 = Pos + Pad div 8,
    case unmarshal_struct(SubTypes, Data1, Pos1) of
	more ->
	    more;
	{ok, Res, Data2, Pos2} ->
	    {ok, list_to_tuple(Res), Data2, Pos2}
    end;

unmarshal({dict, KeyType, ValueType}, Data, Pos) ->
    case unmarshal(uint32, Data, Pos) of
	more ->
	    more;
	{ok, Length, Data1, Pos1} ->
	    case unmarshal_array({struct, [KeyType, ValueType]}, Length, Data1, Pos1) of
		more -> 
		    more;
		{ok, Res, Data2, Pos2} ->
		    {ok, Res, Data2, Pos2}
	    end
    end;

unmarshal(variant, Data, Pos) ->
    case unmarshal(signature, Data, Pos) of
	more -> 
	    more;
	{ok, _, <<>>, _} -> 
	    more;
	{ok, Signature, Data1, Pos1} ->
	    case unmarshal_single_type(Signature) of
		more -> more;
		{ok, Type} ->
		    case unmarshal(Type, Data1, Pos1) of
			more -> more;
			{ok, Value, Data2, Pos2} -> {ok, #dbus_variant{type=Type, value=Value}, Data2, Pos2}
		    end
	    end
    end.


unmarshal_uint(Len, Data, _) when is_integer(Len) andalso byte_size(Data) < Len ->
    more;

unmarshal_uint(Len, Data, Pos) when is_integer(Len) ->
    Bitlen = Len * 8,
    Pad = pad(Len, Pos),
    << 0:Pad, Value:Bitlen/native-unsigned, Data1/binary >> = Data,
    Pos1 = Pos + Pad div 8 + Len,
    {ok, Value, Data1, Pos1}.


unmarshal_int(Len, Data, _) when is_integer(Len) andalso byte_size(Data) < Len ->
    more;

unmarshal_int(Len, Data, Pos) ->
    Bitlen = Len * 8,
    Pad = pad(Len, Pos),
    << 0:Pad, Value:Bitlen/native-signed, Data1/binary >> = Data,
    Pos1 = Pos + Pad div 8 + Len,
    {ok, Value, Data1, Pos1}.


unmarshal_signature(<<>>, Acc) ->
    {ok, lists:flatten(Acc), <<>>};

unmarshal_signature(<<$a, ${, KeySig, Rest/bits>>, Acc) ->
    KeyType = unmarshal_type_code(KeySig),
    case unmarshal_signature(Rest, []) of
	{ok, [], _} -> 
	    more;
	{ok, [ValueType], Rest2} ->
	    unmarshal_signature(Rest2, [Acc, {dict, KeyType, ValueType}]);
	more -> 
 	    more
    end;

unmarshal_signature(<<$a, Rest/bits>>, Acc) ->
    case unmarshal_signature(Rest, []) of
	{ok, [], _} -> more;
	{ok, [Type | Types], <<>>} ->
	    {ok, lists:flatten([Acc, {array, Type}, Types]), <<>>};
	more -> more
    end;

unmarshal_signature(<<$(, Rest/bits>>, Acc) ->
    case unmarshal_signature(Rest, []) of
	{ok, [], _} -> more;
	{ok, Types, Rest2} ->
	    unmarshal_signature(Rest2, [Acc, {struct, Types}]);
	more -> more
    end;

unmarshal_signature(<<$), Rest/bits>>, Acc) ->
    {ok, lists:flatten(Acc), Rest};

unmarshal_signature(<<$}, Rest/bits>>, Acc) ->
    {ok, lists:flatten(Acc), Rest};

unmarshal_signature(<<C, Rest/bits>>, Acc) ->
    Code = unmarshal_type_code(C),
    unmarshal_signature(Rest, [Acc, Code]).


unmarshal_type_code($y) -> byte;
unmarshal_type_code($b) -> boolean;
unmarshal_type_code($n) -> int16;
unmarshal_type_code($q) -> uint16;
unmarshal_type_code($i) -> int32;
unmarshal_type_code($u) -> uint32;
unmarshal_type_code($x) -> int64;
unmarshal_type_code($t) -> uint64;
unmarshal_type_code($d) -> double;
unmarshal_type_code($s) -> string;
unmarshal_type_code($o) -> object_path;
unmarshal_type_code($g) -> signature;
unmarshal_type_code($r) -> struct;
unmarshal_type_code($v) -> variant;
unmarshal_type_code($e) -> dict_entry;
unmarshal_type_code($a) -> array;
unmarshal_type_code(_C) -> throw({error, {bad_type_code, _C}}).


unmarshal_struct(SubTypes, Data, Pos) ->
    unmarshal_struct(SubTypes, Data, [], Pos).


unmarshal_struct([], Data, Acc, Pos) ->
    {ok, lists:reverse(Acc), Data, Pos};

unmarshal_struct([SubType | S], Data, Acc, Pos) ->
    case unmarshal(SubType, Data, Pos) of
	more -> more;
	{ok, Value, Data1, Pos1} ->
	    unmarshal_struct(S, Data1, [Value | Acc], Pos1)
    end.


unmarshal_array(SubType, Length, Data, Pos) ->
    Pad = pad(padding(SubType), Pos),
    if 
	byte_size(Data) < Pad / 8 -> more;
	true ->
	    << 0:Pad, Rest/binary >> = Data,
	    NewPos = Pos + Pad div 8,
	    unmarshal_array(SubType, Length, Rest, [], NewPos)
    end.


unmarshal_array(_SubType, 0, Data, Acc, Pos) ->
    {ok, lists:reverse(Acc), Data, Pos};
unmarshal_array(SubType, Length, Data, Acc, Pos) when is_integer(Length), Length > 0 ->
    case unmarshal(SubType, Data, Pos) of
	more -> more;
	{ok, Value, Data1, Pos1} ->
	    Size = Pos1 - Pos,
	    unmarshal_array(SubType, Length - Size, Data1, [Value | Acc], Pos1)
    end.


unmarshal_list(Type, Data) when is_atom(Type), is_binary(Data) ->
    unmarshal(Type, Data, 0);
unmarshal_list(Types, Data) when is_list(Types), is_binary(Data) ->
    unmarshal_list(Types, Data, [], 0).


unmarshal_list([], Rest, Acc, Pos) ->
    {ok, lists:reverse(Acc), Rest, Pos};
unmarshal_list([Type|T], Data, Acc, Pos) ->
    case unmarshal(Type, Data, Pos) of
	more ->
	    more;
	{ok, Value, Rest, Pos1} ->
	    unmarshal_list(T, Rest, [Value | Acc], Pos1)
    end.


unmarshal_string(LenType, Data, Pos) ->
    case unmarshal(LenType, Data, Pos) of
	more -> more;
	{ok, Length, Data1, _} when byte_size(Data1) < Length ->
	    more;
	{ok, Length, Data1, Pos1} ->
	    << String:Length/binary, 0, Data2/binary >> = Data1,
	    Pos2 = Pos1 + Length + 1,
	    {ok, String, Data2, Pos2}
    end.

%%%
%%% Priv common
%%%
padding(byte)             -> 1;
padding(boolean)          -> 4;
padding(int16)            -> 2;
padding(uint16)           -> 2;
padding(int32)            -> 4;
padding(uint32)           -> 4;
padding(int64)            -> 8;
padding(uint64)           -> 8;
padding(double)           -> 8;
padding(string)           -> 4;
padding(object_path)      -> 4;
padding(signature)        -> 1;
padding({array, _Type})   -> 4;
padding({struct, _Types}) -> 8;
padding(variant)          -> 1;
padding(dict)             -> 4.

pad(Size, Pos) when is_integer(Size) ->
    ((Size - (Pos rem Size)) rem Size) * 8;
pad(Type, Pos) when is_atom(Type); 
		            array =:= element(1, Type);
		            struct =:= element(1, Type)->
    pad(padding(Type), Pos).
