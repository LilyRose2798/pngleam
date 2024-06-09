-module(pngleam_erl).

-export([subUnfilter/2, upUnfilter/2, avgUnfilter/3, paethUnfilter/3, bitArrayToInts/1, bitArrayToInts/2]).

addBytewise(As, Bs) ->
    list_to_binary(lists:zipwith(fun(A, B) -> (A + B) rem 256 end, binary_to_list(As), binary_to_list(Bs), trim)).

avgBytewise(As, Bs) ->
    list_to_binary(lists:zipwith(fun(A, B) -> ((A + B) div 2) rem 256 end, binary_to_list(As), binary_to_list(Bs), trim)).

paethBytewise(As, Bs, Cs) ->
    list_to_binary(lists:zipwith3(fun(A, B, C) ->
        P = A + B - C, % initial estimate
        PA = abs(P - A), % distances to a, b, c
        PB = abs(P - B),
        PC = abs(P - C),
        % return nearest of a,b,c,
        % breaking ties in order a,b,c.
        case (PA =< PB) and (PA =< PC) of
            true -> A;
            false -> case (PB =< PC) of
                true -> B;
                false -> C
            end
        end
    end, binary_to_list(As), binary_to_list(Bs), binary_to_list(Cs), trim)).

doSubUnfilter(Row, BytesPerPixel, Acc, Prev) ->
    case Row of
        <<>> -> Acc;
        <<Curr:BytesPerPixel/binary, Rest/binary>> ->
            New = addBytewise(Curr, Prev),
            doSubUnfilter(Rest, BytesPerPixel, <<Acc/binary, New/binary>>, New)
    end.

subUnfilter(Row, BytesPerPixel) -> doSubUnfilter(Row, BytesPerPixel, <<>>, <<0:(BytesPerPixel * 8)>>).

upUnfilter(Row, Above) -> addBytewise(Row, Above).

doAvgUnfilter(Row, Above, BytesPerPixel, Acc, Prev) ->
    case Row of
        <<>> -> Acc;
        <<Curr:BytesPerPixel/binary, Rest/binary>> ->
            case Above of <<CurrAbove:BytesPerPixel/binary, RestAbove/binary>> ->
                Avg = avgBytewise(Prev, CurrAbove),
                New = addBytewise(Curr, Avg),
                doAvgUnfilter(Rest, RestAbove, BytesPerPixel, <<Acc/binary, New/binary>>, New)
            end
    end.

avgUnfilter(Row, Above, BytesPerPixel) -> doAvgUnfilter(Row, Above, BytesPerPixel, <<>>, <<0:(BytesPerPixel * 8)>>).

doPaethUnfilter(Row, Above, BytesPerPixel, Acc, Prev, PrevAbove) ->
    case Row of
        <<>> -> Acc;
        <<Curr:BytesPerPixel/binary, Rest/binary>> ->
            case Above of <<CurrAbove:BytesPerPixel/binary, RestAbove/binary>> ->
                Paeth = paethBytewise(Prev, CurrAbove, PrevAbove),
                New = addBytewise(Curr, Paeth),
                doPaethUnfilter(Rest, RestAbove, BytesPerPixel, <<Acc/binary, New/binary>>, New, CurrAbove)
            end
    end.

paethUnfilter(Row, Above, BytesPerPixel) -> doPaethUnfilter(Row, Above, BytesPerPixel, <<>>, <<0:(BytesPerPixel * 8)>>, <<0:(BytesPerPixel * 8)>>).

doBitArrayToInts(As, IntSize, Values) ->
    case As of
        <<V:IntSize, Rest/binary>> -> doBitArrayToInts(Rest, IntSize, [V | Values]);
        _ -> Values
    end.
bitArrayToInts(As, IntSize) -> lists:reverse(doBitArrayToInts(As, IntSize, [])).
bitArrayToInts(As) -> bitArrayToInts(As, 8).
