// Copyright 2018 The Flutter team. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:rxdart/subjects.dart' show BehaviorSubject;
import 'package:stack_trace/stack_trace.dart';

/// A Redux-style action. Apps change their overall state by dispatching actions
/// to the [ReduxStore], where they are acted on by middleware, reducers, and
/// afterware in that order.
abstract class ReduxAction {
  const ReduxAction();

  factory ReduxAction.cancelled() => _CancelledAction();
}

/// An action that middleware and afterware methods can return in order to
/// cancel (or "swallow") an action already dispatched to their [ReduxStore]. Because
/// rebloc uses a stream to track [Actions] through the
/// dispatch->middleware->reducer->afterware pipeline, a middleware/afterware
/// method should return something. By returning an instance of this class
/// (which is private to this library), a developer can in effect cancel actions
/// via middleware.
class _CancelledAction extends ReduxAction {
  const _CancelledAction();
}

/// A function that can dispatch an [ReduxAction] to a [ReduxStore].
typedef void DispatchFunction(ReduxAction action);

/// An accumulator for reducer functions.
///
/// [ReduxStore] offers each [Bloc] the opportunity to apply its own reducer
/// functionality in response to incoming [ReduxAction]s by subscribing to the
/// "reducer" stream, which is of type `Stream<Accumulator<S>>`.
///
/// A [Bloc] that does so is expected to use the [ReduxAction] and [state] provided in
/// any [Accumulator] it receives to calculate a new [state], then emit it in a
/// new Accumulator with the original action and new [state]. Alternatively, if
/// the Bloc doesn't want to make a change to the state, it can simply return
/// the Accumulator it was given.
class Accumulator {
  final ReduxAction action;
  final ReduxState state;

  const Accumulator(this.action, this.state);

  Accumulator copyWith(ReduxState newState) => Accumulator(this.action, newState);
}

/// The context in which a middleware or afterware function executes.
///
/// In a manner similar to the streaming architecture used for reducers, [ReduxStore]
/// offers each [Bloc] the chance to apply middleware and afterware
/// functionality to incoming [Actions] by listening to the "dispatch" stream,
/// which is of type `Stream<WareContext<S>>`.
///
/// Middleware and afterware functions can examine the incoming [action] and
/// current [state] of the app and perform side effects (including dispatching
/// new [ReduxAction]s using [dispatcher]. Afterward, they should emit a new
/// [WareContext] for the next [Bloc].
class WareContext {
  final DispatchFunction dispatcher;
  final ReduxState state;
  final ReduxAction action;

  const WareContext(this.dispatcher, this.state, this.action);

  WareContext copyWith(ReduxAction newAction) => WareContext(this.dispatcher, this.state, newAction);
}

class ReduxState {
  final Map<String, dynamic> stateMap;

  ReduxState(this.stateMap);
}

/// A store for app state that manages the dispatch of incoming actions and
/// controls the stream of state objects emitted in response.
///
/// [ReduxStore] performs these tasks:
///
/// - Create a controller for the dispatch/reduce stream using an [initialState]
///   value.
/// - Wire each [Bloc] into the dispatch/reduce stream by calling its
///   [applyMiddleware], [applyReducers], and [applyAfterware] methods.
/// - Expose the [dispatch] method with which a new [ReduxAction] can be dispatched.
class ReduxStore {
  final _dispatchController = StreamController<WareContext>();
  final _afterwareController = StreamController<WareContext>();
  final BehaviorSubject<ReduxState> states;
  final List<Bloc> _blocs;

  static ReduxState buildState(List<Bloc> blocs) {
    Map<String, dynamic> stateMap = {};
    blocs.forEach((v) {
      var initialState = v.initialState;
      if (initialState != null) {
        stateMap[v.moduleName] = v.initialState;
      }
    });
    return ReduxState(stateMap);
  }

  ReduxStore({
    List<Bloc<dynamic>> blocs = const [],
  })  : _blocs = blocs,
        states = BehaviorSubject.seeded(buildState(blocs)) {
    var dispatchStream = _dispatchController.stream.asBroadcastStream();
    var afterwareStream = _afterwareController.stream.asBroadcastStream();

    for (Bloc<dynamic> bloc in blocs) {
      dispatchStream = bloc.applyMiddleware(dispatchStream);
      afterwareStream = bloc.applyAfterware(afterwareStream);
    }

    var reducerStream = dispatchStream.map<Accumulator>((context) => Accumulator(context.action, states.value));

    for (Bloc<dynamic> bloc in blocs) {
      reducerStream = bloc.applyReducer(reducerStream);
    }

    reducerStream.listen((a) {
      assert(a.state != null);
      states.add(a.state);
      _afterwareController.add(WareContext(dispatch, a.state, a.action));
    });

    // Without something listening, the afterware won't be executed.
    afterwareStream.listen((_) {});
  }

  void dispatch(ReduxAction action) {
    print(Trace.current().frames[1]);
    _dispatchController.add(WareContext(dispatch, states.value, action));
  }

  /// Invokes the dispose method on each Bloc, so they can deallocate/close any
  /// long-lived resources.
  void dispose() => _blocs.forEach((b) => b.dispose());
}

/// A business logic component that can apply middleware, reducer, and
/// afterware functionality to a [ReduxStore] by transforming the streams passed into
/// its [applyMiddleware], [applyReducer], and [applyAfterware] methods.
abstract class Bloc<S> {
  String get moduleName => this.runtimeType.toString();

  S get initialState => null;

  Stream<WareContext> applyMiddleware(Stream<WareContext> input);

  Stream<Accumulator> applyReducer(Stream<Accumulator> input);

  Stream<WareContext> applyAfterware(Stream<WareContext> input);

  void dispose();
}

/// A convenience [Bloc] class that handles the stream mapping bits for you.
/// Subclasses can simply override [middleware], [reducer], and [afterware] to
/// add their implementations.
abstract class SimpleBloc<S> implements Bloc<S> {
  @override
  Stream<WareContext> applyMiddleware(Stream<WareContext> input) {
    return input.asyncMap((context) async {
      return context.copyWith(await middleware(context.dispatcher, context.state, context.action));
    });
  }

  @override
  Stream<Accumulator> applyReducer(Stream<Accumulator> input) {
    return input.map<Accumulator>((accumulator) {
      var moduleState = accumulator.state.stateMap[moduleName];
      if (moduleState is S) {
        accumulator.state.stateMap[moduleName] = reducer(moduleState, accumulator.action);
      }
      return accumulator.copyWith(accumulator.state);
    });
  }

  @override
  Stream<WareContext> applyAfterware(Stream<WareContext> input) {
    return input.asyncMap((context) async {
      return context.copyWith(await afterware(context.dispatcher, context.state, context.action));
    });
  }

  FutureOr<ReduxAction> middleware(DispatchFunction dispatcher, ReduxState state, ReduxAction action) => action;

  FutureOr<ReduxAction> afterware(DispatchFunction dispatcher, ReduxState state, ReduxAction action) => action;

  S reducer(S state, ReduxAction action) => state;

  @mustCallSuper
  void dispose() {}
}
