import 'package:mobx/src/core/action.dart';
import 'package:mobx/src/core/atom.dart';
import 'package:mobx/src/core/computed.dart';
import 'package:mobx/src/core/derivation.dart';
import 'package:mobx/src/core/reaction.dart';

class _ReactiveState {
  int batch = 0;

  int nextIdCounter = 0;

  Derivation trackingDerivation;
  List<Reaction> pendingReactions = [];
  bool isRunningReactions = false;
  List<Atom> pendingUnobservations = [];
}

class ReactiveContext {
  final _ReactiveState _state = _ReactiveState();

  int get nextId => ++_state.nextIdCounter;

  void startBatch() {
    _state.batch++;
  }

  void endBatch() {
    if (--_state.batch == 0) {
      runReactions();

      for (var i = 0; i < _state.pendingUnobservations.length; i++) {
        final ob = _state.pendingUnobservations[i]
          ..isPendingUnobservation = false;

        if (ob.observers.isEmpty) {
          if (ob.isBeingObserved) {
            // if this observable had reactive observers, trigger the hooks
            ob
              ..isBeingObserved = false
              ..notifyOnBecomeUnobserved();
          }

          if (ob is ComputedValue) {
            ob.suspend();
          }
        }
      }

      _state.pendingUnobservations = [];
    }
  }

  T trackDerivation<T>(Derivation d, T Function() fn) {
    final prevDerivation = _state.trackingDerivation;
    _state.trackingDerivation = d;

    resetDerivationState(d);
    d.newObservables = Set();

    final result = fn();

    _state.trackingDerivation = prevDerivation;
    bindDependencies(d);

    return result;
  }

  void reportObserved(Atom atom) {
    final derivation = _state.trackingDerivation;

    if (derivation != null) {
      derivation.newObservables.add(atom);
      if (!atom.isBeingObserved) {
        atom
          ..isBeingObserved = true
          ..notifyOnBecomeObserved();
      }
    }
  }

  void bindDependencies(Derivation derivation) {
    final staleObservables =
        derivation.observables.difference(derivation.newObservables);
    final newObservables =
        derivation.newObservables.difference(derivation.observables);
    var lowestNewDerivationState = DerivationState.upToDate;

    // Add newly found observables
    for (final observable in newObservables) {
      observable.addObserver(derivation);

      // ComputedValue = ObservableValue + Derivation
      if (observable is ComputedValue) {
        if (observable.dependenciesState.index >
            lowestNewDerivationState.index) {
          lowestNewDerivationState = observable.dependenciesState;
        }
      }
    }

    // Remove previous observables
    for (final ob in staleObservables) {
      ob.removeObserver(derivation);
    }

    if (lowestNewDerivationState != DerivationState.upToDate) {
      derivation
        ..dependenciesState = lowestNewDerivationState
        ..onBecomeStale();
    }

    derivation
      ..observables = derivation.newObservables
      ..newObservables = Set(); // No need for newObservables beyond this point
  }

  void addPendingReaction(Reaction reaction) {
    _state.pendingReactions.add(reaction);
  }

  void runReactions() {
    if (_state.batch > 0 || _state.isRunningReactions) {
      return;
    }

    _state.isRunningReactions = true;

    for (final reaction in _state.pendingReactions) {
      reaction.run();
    }

    _state
      ..pendingReactions = []
      ..isRunningReactions = false;
  }

  void propagateChanged(Atom atom) {
    if (atom.lowestObserverState == DerivationState.stale) {
      return;
    }

    atom.lowestObserverState = DerivationState.stale;

    for (final observer in atom.observers) {
      if (observer.dependenciesState == DerivationState.upToDate) {
        observer.onBecomeStale();
      }
      observer.dependenciesState = DerivationState.stale;
    }
  }

  void propagatePossiblyChanged(Atom atom) {
    if (atom.lowestObserverState != DerivationState.upToDate) {
      return;
    }

    atom.lowestObserverState = DerivationState.possiblyStale;

    for (final observer in atom.observers) {
      if (observer.dependenciesState == DerivationState.upToDate) {
        observer
          ..dependenciesState = DerivationState.possiblyStale
          ..onBecomeStale();
      }
    }
  }

  void propagateChangeConfirmed(Atom atom) {
    if (atom.lowestObserverState == DerivationState.stale) {
      return;
    }

    atom.lowestObserverState = DerivationState.stale;

    for (final observer in atom.observers) {
      if (observer.dependenciesState == DerivationState.possiblyStale) {
        observer.dependenciesState = DerivationState.stale;
      } else if (observer.dependenciesState == DerivationState.upToDate) {
        atom.lowestObserverState = DerivationState.upToDate;
      }
    }
  }

  void clearObservables(Derivation derivation) {
    final observables = derivation.observables;
    derivation.observables = Set();

    for (final x in observables) {
      x.removeObserver(derivation);
    }

    derivation.dependenciesState = DerivationState.notTracking;
  }

  void enqueueForUnobservation(Atom atom) {
    if (atom.isPendingUnobservation) {
      return;
    }

    atom.isPendingUnobservation = true;
    _state.pendingUnobservations.add(atom);
  }

  void resetDerivationState(Derivation d) {
    if (d.dependenciesState == DerivationState.upToDate) {
      return;
    }

    d.dependenciesState = DerivationState.upToDate;
    for (final obs in d.observables) {
      obs.lowestObserverState = DerivationState.upToDate;
    }
  }

  bool shouldCompute(Derivation derivation) {
    switch (derivation.dependenciesState) {
      case DerivationState.upToDate:
        return false;

      case DerivationState.notTracking:
      case DerivationState.stale:
        return true;

      case DerivationState.possiblyStale:
        return untracked(() {
          for (final obs in derivation.observables) {
            if (obs is ComputedValue) {
              // Force a computation
              obs.value;

              if (derivation.dependenciesState == DerivationState.stale) {
                return true;
              }
            }
          }

          resetDerivationState(derivation);
          return false;
        });
    }

    return false;
  }

  bool isInBatch() => _state.batch > 0;

  bool isComputingDerivation() => _state.trackingDerivation != null;

  Derivation untrackedStart() {
    final prevDerivation = _state.trackingDerivation;
    _state.trackingDerivation = null;
    return prevDerivation;
  }

  // ignore: use_setters_to_change_properties
  void untrackedEnd(Derivation prevDerivation) {
    _state.trackingDerivation = prevDerivation;
  }
}

class MobXException implements Exception {
  MobXException(this.message);

  String message;
}

final ReactiveContext ctx = ReactiveContext();