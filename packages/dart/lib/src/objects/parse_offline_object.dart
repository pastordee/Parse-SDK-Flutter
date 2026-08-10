part of '../../parse_server_sdk.dart';

extension ParseObjectOffline on ParseObject {
  // ─── Single-object operations ────────────────────────────────────────────

  /// Save this object to local storage for offline access.
  Future<void> saveToLocalCache() async {
    final CoreStore store = ParseCoreData().getStore();
    final String cacheKey = 'offline_cache_$parseClassName';
    final Map<String, String> map = await _loadMap(store, cacheKey);
    if (objectId == null) {
      print(
        'ParseObjectOffline.saveToLocalCache: skipping object with no objectId '
        'for $parseClassName',
      );
      return;
    }
    map[objectId!] = json.encode(toJson(full: true));
    await _saveMap(store, cacheKey, map);
    print('ParseObjectOffline: saved $objectId to cache for $parseClassName');
  }

  /// Remove this object from local storage.
  Future<void> removeFromLocalCache() async {
    if (objectId == null) return;
    final CoreStore store = ParseCoreData().getStore();
    final String cacheKey = 'offline_cache_$parseClassName';
    final Map<String, String> map = await _loadMap(store, cacheKey);
    if (map.remove(objectId) != null) {
      await _saveMap(store, cacheKey, map);
      print(
        'ParseObjectOffline: removed $objectId from cache for $parseClassName',
      );
    }
  }

  /// Partially update a cached object's fields without a full re-encode.
  ///
  /// Returns `true` if the object was found and updated.
  Future<bool> updateInLocalCache(Map<String, dynamic> updates) async {
    if (objectId == null) return false;
    final CoreStore store = ParseCoreData().getStore();
    final String cacheKey = 'offline_cache_$parseClassName';
    final Map<String, String> map = await _loadMap(store, cacheKey);
    final String? existing = map[objectId];
    if (existing == null) return false;
    try {
      final Map<String, dynamic> obj =
          json.decode(existing) as Map<String, dynamic>;
      obj.addAll(updates);
      map[objectId!] = json.encode(obj);
      await _saveMap(store, cacheKey, map);
      print(
        'ParseObjectOffline: updated $objectId in cache for $parseClassName',
      );
      return true;
    } catch (e) {
      print('ParseObjectOffline.updateInLocalCache: error for $objectId: $e');
      return false;
    }
  }

  // ─── Batch / static operations ───────────────────────────────────────────

  /// Load a single object by objectId from local storage. O(1) lookup.
  static Future<ParseObject?> loadFromLocalCache(
    String className,
    String objectId,
  ) async {
    final CoreStore store = ParseCoreData().getStore();
    final Map<String, String> map = await _loadMap(
      store,
      'offline_cache_$className',
    );
    final String? raw = map[objectId];
    if (raw == null) return null;
    try {
      return ParseObject(
        className,
      ).fromJson(json.decode(raw) as Map<String, dynamic>);
    } catch (e) {
      print(
        'ParseObjectOffline.loadFromLocalCache: corrupt entry for $objectId '
        'in $className — $e',
      );
      return null;
    }
  }

  /// Load all objects of a class from local storage.
  /// Load every cached object of [className].
  ///
  /// The offline store holds one bucket per class, so callers that only want a
  /// subset (e.g. the messages of ONE conversation) can pass [where] to filter
  /// during the load — non-matching entries are skipped without being added to
  /// the result. Without it, ALL cached objects of the class are returned.
  static Future<List<ParseObject>> loadAllFromLocalCache(
    String className, {
    bool Function(ParseObject object)? where,
  }) async {
    final CoreStore store = ParseCoreData().getStore();
    final Map<String, String> map = await _loadMap(
      store,
      'offline_cache_$className',
    );
    final List<ParseObject> results = [];
    for (final entry in map.entries) {
      try {
        final ParseObject object = ParseObject(
          className,
        ).fromJson(json.decode(entry.value) as Map<String, dynamic>);
        if (where == null || where(object)) {
          results.add(object);
        }
      } catch (e) {
        print(
          'ParseObjectOffline.loadAllFromLocalCache: skipping corrupt entry '
          '${entry.key} for $className — $e',
        );
      }
    }
    print(
      'ParseObjectOffline: loaded ${results.length} objects from cache for '
      '$className${where != null ? ' (filtered)' : ''}',
    );
    return results;
  }

  /// Save a batch of objects efficiently. O(1) per object — no re-read needed.
  static Future<void> saveAllToLocalCache(
    String className,
    List<ParseObject> objects,
  ) async {
    if (objects.isEmpty) return;
    final CoreStore store = ParseCoreData().getStore();
    final String cacheKey = 'offline_cache_$className';
    final Map<String, String> map = await _loadMap(store, cacheKey);

    int added = 0;
    int updated = 0;
    int failed = 0;
    for (final obj in objects) {
      final id = obj.objectId;
      if (id == null) {
        print(
          'ParseObjectOffline.saveAllToLocalCache: skipping object without '
          'objectId for $className',
        );
        continue;
      }
      // Encode each object independently so one bad object (e.g. a value that
      // fails to serialize) can't abort the whole batch and prevent every other
      // item — including a freshly-added one — from being cached.
      try {
        final encoded = json.encode(obj.toJson(full: true));
        map.containsKey(id) ? updated++ : added++;
        map[id] = encoded;
      } catch (e) {
        failed++;
        print(
          'ParseObjectOffline.saveAllToLocalCache: skipping object $id '
          '(createdAt=${obj.createdAt?.toIso8601String()}) for '
          '$className — encode failed: $e',
        );
      }
    }

    await _saveMap(store, cacheKey, map);
    print(
      'ParseObjectOffline: batch saved to $className. '
      'Added: $added, Updated: $updated, Failed: $failed, Total: ${map.length}',
    );
  }

  /// Returns all cached objectIds for a class. O(1) — no JSON decoding.
  static Future<List<String>> getAllObjectIdsInLocalCache(
    String className,
  ) async {
    final CoreStore store = ParseCoreData().getStore();
    final Map<String, String> map = await _loadMap(
      store,
      'offline_cache_$className',
    );
    return map.keys.toList();
  }

  /// Returns true if an object with the given id exists in the cache. O(1).
  static Future<bool> existsInLocalCache(
    String className,
    String objectId,
  ) async {
    final CoreStore store = ParseCoreData().getStore();
    final Map<String, String> map = await _loadMap(
      store,
      'offline_cache_$className',
    );
    return map.containsKey(objectId);
  }

  /// Wipes the entire cache for a class.
  static Future<void> clearLocalCacheForClass(String className) async {
    final CoreStore store = ParseCoreData().getStore();
    final String cacheKey = 'offline_cache_$className';
    // Remove BOTH formats. Reads and writes go through the `_v2` map key, so
    // dropping only the legacy list key left the actual cache fully intact and
    // made this a silent no-op.
    await store.remove('${cacheKey}_v2');
    await store.remove(cacheKey);
    print('ParseObjectOffline: cleared cache for $className');
  }

  /// Sync: pushes every cached object to the server.
  ///
  /// Only call this when you know the local copy is authoritative (e.g. after
  /// collecting edits while offline). Objects whose server version may be newer
  /// should be reconciled before calling this.
  static Future<void> syncLocalCacheWithServer(
    String className, {
    bool Function(ParseObject obj)? shouldSync,
  }) async {
    final List<ParseObject> objects = await loadAllFromLocalCache(className);
    int synced = 0;
    int skipped = 0;
    for (final obj in objects) {
      if (shouldSync != null && !shouldSync(obj)) {
        skipped++;
        continue;
      }
      final response = await obj.save();
      if (response.success) {
        synced++;
      } else {
        print(
          'ParseObjectOffline.syncLocalCacheWithServer: failed to save '
          '${obj.objectId} — ${response.error?.message}',
        );
      }
    }
    print(
      'ParseObjectOffline: sync complete for $className. '
      'Synced: $synced, Skipped: $skipped',
    );
  }

  // ─── Internal helpers ────────────────────────────────────────────────────

  // The cache is stored as a single JSON-encoded Map<String, String> keyed by
  // objectId. This gives O(1) lookups and avoids scanning every entry for id
  // comparisons. The old format (List<String>) is migrated on first read.
  static Future<Map<String, String>> _loadMap(
    CoreStore store,
    String cacheKey,
  ) async {
    // Try new map format first.
    final String? mapJson = await store.getString('${cacheKey}_v2');
    if (mapJson != null) {
      try {
        final decoded = json.decode(mapJson) as Map<String, dynamic>;
        return decoded.map((k, v) => MapEntry(k, v as String));
      } catch (_) {}
    }

    // Migrate from old List<String> format.
    final rawList = await store.getStringList(cacheKey);
    if (rawList == null || rawList.isEmpty) return {};
    final Map<String, String> migrated = {};
    for (final s in rawList) {
      try {
        final obj = json.decode(s) as Map<String, dynamic>;
        final id = obj['objectId'] as String?;
        if (id != null) migrated[id] = s;
      } catch (_) {}
    }
    if (migrated.isNotEmpty) {
      // Write migrated data in new format and remove old list.
      await store.setString('${cacheKey}_v2', json.encode(migrated));
      await store.remove(cacheKey);
      print(
        'ParseObjectOffline: migrated ${migrated.length} entries from list '
        'format to map format for $cacheKey',
      );
    }
    return migrated;
  }

  static Future<void> _saveMap(
    CoreStore store,
    String cacheKey,
    Map<String, String> map,
  ) async {
    await store.setString('${cacheKey}_v2', json.encode(map));
  }
}
