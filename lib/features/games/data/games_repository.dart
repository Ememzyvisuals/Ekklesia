import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/shared/result.dart';
import '../domain/game_entry.dart';

/// Reads the `games` collection from Firestore. There is deliberately no
/// seed data and no mock fallback — see GameEntry's doc comment for why an
/// automated catalog source doesn't exist. This repository is fully
/// functional against a real (currently empty) Firestore collection, so
/// adding a document there makes it appear with zero code changes; that's
/// the "modular catalog" the spec asks for, just without a fake data source
/// pretending one already exists.
class GamesRepository {
  GamesRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Future<Result<List<GameEntry>>> fetchCatalog() async {
    try {
      final snapshot =
          await _firestore.collection('games').orderBy('title').get();

      final entries = snapshot.docs
          .map((doc) => GameEntry.fromFirestore(doc.id, doc.data()))
          .toList();

      return Result.success(entries);
    } on FirebaseException catch (e) {
      return Result.failure(AppFailure(
        message:
            'Couldn\'t load Games right now — check your connection and try again.',
        debugDetail: '${e.code}: ${e.message}',
      ));
    } catch (e) {
      return Result.failure(AppFailure(
        message: 'Something went wrong loading Games.',
        debugDetail: e.toString(),
      ));
    }
  }
}
