part of 'package:parse_server_sdk_flutter/parse_server_sdk_flutter.dart';

/// A widget that displays a live sliver list of Parse objects.
///
/// This widget is designed to be used inside a [CustomScrollView].
/// To control refresh and pagination from a parent widget, use a [GlobalKey]:
///
/// ```dart
/// final listKey = GlobalKey<ParseLiveSliverListWidgetState<MyObject>>();
///
/// // In your CustomScrollView
/// ParseLiveSliverListWidget<MyObject>(
///   key: listKey,
///   query: query,
///   fromJson: MyObject.fromJson,
/// ),
///
/// // To refresh
/// listKey.currentState?.refreshData();
///
/// // To load more (if pagination is enabled)
/// listKey.currentState?.loadMoreData();
/// ```
class ParseLiveSliverListWidget<T extends sdk.ParseObject>
    extends StatefulWidget {
  const ParseLiveSliverListWidget({
    super.key,
    required this.query,
    this.listLoadingElement,
    this.queryEmptyElement,
    this.duration = const Duration(milliseconds: 300),
    this.childBuilder,
    this.removedItemBuilder,
    this.listenOnAllSubItems,
    this.listeningIncludes,
    this.lazyLoading = true,
    this.preloadedColumns,
    this.excludedColumns,
    this.pagination = false,
    this.pageSize = 100,
    this.nonPaginatedLimit = 1000,
    this.paginationLoadingElement,
    this.footerBuilder,
    this.preloadItemThreshold = 5,
    this.cacheSize = 50,
    this.offlineMode = false,
    this.cacheFilter,
    this.cacheComparator,
    this.optimisticItems,
    this.optimisticKeyField,
    this.onOptimisticResolved,
    this.fromJson,
  });

  final sdk.QueryBuilder<T> query;
  final Widget? listLoadingElement;
  final Widget? queryEmptyElement;
  final Duration duration;

  final ChildBuilder<T>? childBuilder;
  final ChildBuilder<T>? removedItemBuilder;

  final bool? listenOnAllSubItems;
  final List<String>? listeningIncludes;

  final bool lazyLoading;
  final List<String>? preloadedColumns;
  final List<String>? excludedColumns;

  final bool pagination;
  final Widget? paginationLoadingElement;
  final FooterBuilder? footerBuilder;

  /// How many items from the end of the list to begin prefetching the next page.
  /// Index-based (item-height-independent) so infinite scroll stays smooth: as
  /// soon as an item within this many rows of the end is built, the next page
  /// starts loading in the background instead of waiting until the very bottom.
  final int preloadItemThreshold;
  final int pageSize;
  final int nonPaginatedLimit;
  final int cacheSize;
  final bool offlineMode;

  /// Scope offline-cached items to this query (the offline store keeps one
  /// bucket per class); applied inside ParseObjectOffline.loadAllFromLocalCache.
  final bool Function(sdk.ParseObject object)? cacheFilter;

  /// Order offline-cached items to match the query sort; the server load
  /// then reconciles the final order.
  final int Function(T a, T b)? cacheComparator;

  /// Optimistic (pending) items to display before the server confirms them.
  ///
  /// The widget merges these ahead of the server-backed items (at index 0) and
  /// renders each with [sdk.ParseLiveListElementSnapshot.isOptimistic] = true so
  /// the childBuilder can style them (dim, spinner, …). When a real object
  /// arrives (server load or LiveQuery) whose [optimisticKeyField] value matches
  /// an optimistic item, the real one supersedes it (no duplicate) and
  /// [onOptimisticResolved] fires so the caller can prune its own list.
  ///
  /// The caller owns and mutates this list; order it as you want it to appear
  /// at the start of the list (e.g. newest-first for a reversed chat).
  final ValueListenable<List<T>>? optimisticItems;

  /// Field name used to match an optimistic item to the real object that later
  /// arrives. Defaults to `objectId` when null (useful with custom objectIds);
  /// set it to a caller-generated correlation field (e.g. a client temp id) when
  /// the server assigns the objectId.
  final String? optimisticKeyField;

  /// Called once when a real object supersedes an optimistic one, with both the
  /// confirmed item and the optimistic item it replaced. Use it to remove the
  /// resolved entry from [optimisticItems].
  final void Function(T confirmed, T optimistic)? onOptimisticResolved;

  /// Optional. Rebuilds a typed [T] from a cached object's JSON when offline.
  /// Leave it null to fall back to cloning the query's prototype object, which
  /// resolves registered subclasses the same way ParseLiveList does.
  final T Function(Map<String, dynamic> json)? fromJson;

  @override
  State<ParseLiveSliverListWidget<T>> createState() =>
      ParseLiveSliverListWidgetState<T>();

  static Widget defaultChildBuilder<T extends sdk.ParseObject>(
    BuildContext context,
    sdk.ParseLiveListElementSnapshot<T> snapshot, [
    int? index,
  ]) {
    if (snapshot.failed) {
      return const Text('Something went wrong!');
    } else if (snapshot.hasData) {
      return ListTile(
        title: Text(
          snapshot.loadedData?.get<String>(sdk.keyVarObjectId) ??
              'Missing Data!',
        ),
        subtitle: index != null ? Text('Item #$index') : null,
      );
    } else {
      return const ListTile(leading: CircularProgressIndicator());
    }
  }
}

/// State class for [ParseLiveSliverListWidget].
///
/// Exposes [refreshData] and [loadMoreData] methods that can be called
/// via a [GlobalKey] to control the widget from a parent.
class ParseLiveSliverListWidgetState<T extends sdk.ParseObject>
    extends State<ParseLiveSliverListWidget<T>>
    with ConnectivityHandlerMixin<ParseLiveSliverListWidget<T>> {
  CachedParseLiveList<T>? _liveList;
  final ValueNotifier<bool> _noDataNotifier = ValueNotifier<bool>(true);
  final List<T> _items = <T>[];

  LoadMoreStatus _loadMoreStatus = LoadMoreStatus.idle;
  int _currentPage = 0;
  bool _hasMoreData = true;

  /// Whether more data can be loaded.
  bool get hasMoreData => _hasMoreData;

  /// Current load more status.
  LoadMoreStatus get loadMoreStatus => _loadMoreStatus;

  @override
  String get connectivityLogPrefix => 'ParseLiveSliverListWidget';

  @override
  bool get isOfflineModeEnabled => widget.offlineMode;

  @override
  void disposeLiveList() {
    _liveList?.dispose();
    _liveList = null;
  }

  @override
  Future<void> loadDataFromServer() => _loadData();

  @override
  Future<void> loadDataFromCache() => _loadFromCache();

  @override
  void initState() {
    super.initState();

    // Rebuild when the caller mutates its optimistic list.
    widget.optimisticItems?.addListener(_onOptimisticChanged);

    // Initialize connectivity and load initial data
    initConnectivityHandler();
  }

  @override
  void didUpdateWidget(covariant ParseLiveSliverListWidget<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-wire the optimistic listener if the caller swapped the listenable.
    if (!identical(oldWidget.optimisticItems, widget.optimisticItems)) {
      oldWidget.optimisticItems?.removeListener(_onOptimisticChanged);
      widget.optimisticItems?.addListener(_onOptimisticChanged);
    }
  }

  void _onOptimisticChanged() {
    if (mounted) setState(() {});
  }

  // Keys of optimistic items already reported resolved, so onOptimisticResolved
  // fires at most once per item.
  final Set<String> _resolvedOptimisticKeys = <String>{};

  // The correlation key for [obj]: the optimisticKeyField value, or objectId
  // when no field is set (custom-objectId case).
  String? _optimisticKeyOf(T obj) {
    final String? field = widget.optimisticKeyField;
    if (field == null || field == sdk.keyVarObjectId) return obj.objectId;
    final dynamic v = obj.get<dynamic>(field);
    return v?.toString();
  }

  // Optimistic items not yet superseded by a real item in [_items].
  List<T> _visibleOptimisticItems() {
    final List<T>? opt = widget.optimisticItems?.value;
    if (opt == null || opt.isEmpty) return const [];
    final Set<String> realKeys = <String>{};
    for (final T it in _items) {
      final String? k = _optimisticKeyOf(it);
      if (k != null) realKeys.add(k);
    }
    return opt.where((T o) {
      final String? k = _optimisticKeyOf(o);
      return k == null || !realKeys.contains(k);
    }).toList();
  }

  // After [_items] changes, notify the caller for any optimistic item that has
  // now been confirmed by a real object so it can prune its list.
  void _reconcileOptimistic() {
    final void Function(T, T)? cb = widget.onOptimisticResolved;
    final List<T>? opt = widget.optimisticItems?.value;
    if (cb == null || opt == null || opt.isEmpty) return;
    final Map<String, T> realByKey = <String, T>{};
    for (final T it in _items) {
      final String? k = _optimisticKeyOf(it);
      if (k != null) realByKey[k] = it;
    }
    for (final T o in opt) {
      final String? k = _optimisticKeyOf(o);
      if (k != null &&
          realByKey.containsKey(k) &&
          _resolvedOptimisticKeys.add(k)) {
        cb(realByKey[k] as T, o);
      }
    }
  }

  Future<void> _loadFromCache() async {
    if (!isOfflineModeEnabled) {
      debugPrint(
        '$connectivityLogPrefix Offline mode disabled, skipping cache load.',
      );
      _items.clear();
      _noDataNotifier.value = true;
      if (mounted) setState(() {});
      return;
    }

    debugPrint('$connectivityLogPrefix Loading data from cache...');
    _items.clear();

    try {
      final cached = await ParseObjectOffline.loadAllFromLocalCache(
        widget.query.object.parseClassName,
        where: widget.cacheFilter,
      );
      for (final obj in cached) {
        try {
          _items.add(
            cachedObjectFromJson<T>(
              widget.query,
              widget.fromJson,
              obj.toJson(full: true),
            ),
          );
        } catch (e) {
          debugPrint(
            '$connectivityLogPrefix Error deserializing cached object: $e',
          );
        }
      }
      if (widget.cacheComparator != null) {
        _items.sort(widget.cacheComparator);
      } else {
        // No explicit comparator — fall back to the query's own order so newly
        // cached items land in their correct spot (e.g. -createdAt = newest on
        // top) instead of at the bottom in cache-insertion order.
        final Comparator<T>? auto = cacheOrderComparatorFromQuery<T>(
          widget.query,
        );
        if (auto != null) _items.sort(auto);
      }
      debugPrint(
        '$connectivityLogPrefix Loaded ${_items.length} items from cache for ${widget.query.object.parseClassName}',
      );
    } catch (e) {
      debugPrint('$connectivityLogPrefix Error loading data from cache: $e');
    }

    _noDataNotifier.value = _items.isEmpty;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadData() async {
    // If offline, attempt to load from cache and exit
    if (isOffline) {
      debugPrint(
        '$connectivityLogPrefix Offline: Skipping server load, relying on cache.',
      );
      if (isOfflineModeEnabled) {
        await loadDataFromCache();
      }
      return;
    }

    // --- Online Loading Logic ---
    debugPrint('$connectivityLogPrefix Loading initial data from server...');
    List<T> itemsToCacheBatch = []; // Prepare list for batch caching

    try {
      // Reset pagination and state
      if (widget.pagination) {
        _currentPage = 0;
        _loadMoreStatus = LoadMoreStatus.idle;
        _hasMoreData = true;
      }
      _items.clear();
      // OFFLINE-FIRST: seed from the cache so rows show immediately while the
      // server query runs (the builder shows the loading indicator only when
      // nothing is cached). Server results reconcile (swap) below.
      if (widget.offlineMode) {
        await _loadFromCache();
      }
      _noDataNotifier.value = _items.isEmpty;
      if (mounted) setState(() {});

      // Prepare query
      final initialQuery = QueryBuilder<T>.copy(widget.query);
      if (widget.pagination) {
        initialQuery
          ..setAmountToSkip(0)
          ..setLimit(widget.pageSize);
      } else {
        if (!initialQuery.limiters.containsKey('limit')) {
          initialQuery.setLimit(widget.nonPaginatedLimit);
        }
      }

      // Fetch from server using ParseLiveList for live updates
      final originalLiveList = await sdk.ParseLiveList.create(
        initialQuery,
        listenOnAllSubItems: widget.listenOnAllSubItems,
        listeningIncludes: widget.lazyLoading
            ? (widget.listeningIncludes ?? [])
            : widget.listeningIncludes,
        lazyLoading: widget.lazyLoading,
        preloadedColumns: widget.lazyLoading
            ? (widget.preloadedColumns ?? [])
            : widget.preloadedColumns,
      );

      final liveList = CachedParseLiveList<T>(
        originalLiveList,
        widget.cacheSize,
        widget.lazyLoading,
      );
      _liveList?.dispose(); // Dispose previous list if any
      _liveList = liveList;

      // Build the fresh list from server, then swap it in atomically so any
      // cached rows shown above are replaced without a blank frame.
      final List<T> serverItems = <T>[];
      if (liveList.size > 0) {
        for (int i = 0; i < liveList.size; i++) {
          // Use preLoaded data for initial display speed
          final item = liveList.getPreLoadedAt(i);
          if (item != null) {
            serverItems.add(item);
            // Add the item fetched from server to the cache batch if offline mode is on
            if (widget.offlineMode) {
              itemsToCacheBatch.add(item);
            }
          }
        }
      }

      // --- Update UI FIRST ---
      _items
        ..clear()
        ..addAll(serverItems);
      _noDataNotifier.value = _items.isEmpty;
      if (mounted) {
        setState(() {}); // Display fetched items
      }
      // --- End UI Update ---

      // Confirm any optimistic items now present in the server results.
      _reconcileOptimistic();

      // --- Trigger Background Batch Cache AFTER UI update ---
      if (itemsToCacheBatch.isNotEmpty) {
        // Don't await, let it run in background
        _saveBatchToCache(itemsToCacheBatch);
      }
      // --- End Trigger ---

      // Drop cache entries the server no longer returns (deleted/unpublished),
      // so they don't flash on the next open. Scoped + non-paginated only.
      pruneStaleOfflineCache<T>(
        query: widget.query,
        cacheFilter: widget.cacheFilter,
        offlineMode: widget.offlineMode,
        pagination: widget.pagination,
        serverItems: serverItems,
        logPrefix: connectivityLogPrefix,
      );

      // --- Trigger Proactive Cache for Next Page ---
      if (widget.pagination && _hasMoreData) {
        // Only if pagination is on and initial load wasn't empty
        _proactivelyCacheNextPage(1); // Start caching page 1 (index 1)
      }
      // --- End Proactive Cache Trigger ---

      // --- Stream Listener ---
      liveList.stream.listen(
        (event) {
          if (!mounted) return; // Avoid processing if widget is disposed

          T? objectToCache; // For single item cache updates from stream

          try {
            // Wrap event processing in try-catch
            if (event is sdk.ParseLiveListAddEvent<sdk.ParseObject>) {
              final T addedItem = event.object;
              setState(() {
                _items.insert(event.index, addedItem);
              });
              objectToCache = addedItem;
            } else if (event is sdk.ParseLiveListDeleteEvent<sdk.ParseObject>) {
              if (event.index >= 0 && event.index < _items.length) {
                final removedItem = _items.removeAt(event.index);
                setState(() {});
                if (widget.offlineMode) {
                  // Remove deleted item from cache immediately
                  removedItem.removeFromLocalCache().catchError((e) {
                    debugPrint(
                      '$connectivityLogPrefix Error removing item ${removedItem.objectId} from cache: $e',
                    );
                  });
                }
              } else {
                debugPrint(
                  '$connectivityLogPrefix LiveList Delete Event: Invalid index ${event.index}, list size ${_items.length}',
                );
              }
            } else if (event is sdk.ParseLiveListUpdateEvent<sdk.ParseObject>) {
              final T updatedItem = event.object;
              if (event.index >= 0 && event.index < _items.length) {
                setState(() {
                  _items[event.index] = updatedItem;
                });
                objectToCache = updatedItem;
              } else {
                debugPrint(
                  '$connectivityLogPrefix LiveList Update Event: Invalid index ${event.index}, list size ${_items.length}',
                );
              }
            }

            // Save single updates from stream immediately if offline mode is on
            if (widget.offlineMode && objectToCache != null) {
              objectToCache.saveToLocalCache().catchError((e) {
                debugPrint(
                  '$connectivityLogPrefix Error saving stream update for ${objectToCache?.objectId} to cache: $e',
                );
              });
            }

            // A real add/update from LiveQuery may confirm an optimistic item.
            if (objectToCache != null) _reconcileOptimistic();

            _noDataNotifier.value = _items.isEmpty;
          } catch (e) {
            debugPrint(
              '$connectivityLogPrefix Error processing stream event: $e',
            );
          }
        },
        onError: (error) {
          debugPrint('$connectivityLogPrefix LiveList Stream Error: $error');
          if (mounted) {
            setState(() {
              /* Potentially update state to show error */
            });
          }
        },
      );
      // --- End Stream Listener ---
    } catch (e) {
      debugPrint('$connectivityLogPrefix Error loading data: $e');
      _noDataNotifier.value = _items.isEmpty;
      if (mounted) {
        setState(() {}); // Update UI to potentially show empty/error state
      }
    }
  }

  // --- Helper to Save Batch to Cache (Handles Fetch if Lazy Loading) ---
  Future<void> _saveBatchToCache(List<T> itemsToSave) async {
    if (itemsToSave.isEmpty || !widget.offlineMode) return;

    debugPrint(
      '$connectivityLogPrefix Saving batch of ${itemsToSave.length} items to cache...',
    );
    Stopwatch stopwatch = Stopwatch()..start();

    List<T> itemsToSaveFinal = [];
    List<Future<void>> fetchFutures = [];

    // First, handle potential fetches if lazy loading is enabled
    if (widget.lazyLoading) {
      for (final item in itemsToSave) {
        if (!item.containsKey(sdk.keyVarUpdatedAt)) {
          fetchFutures.add(
            item
                .fetch()
                .then((_) {
                  itemsToSaveFinal.add(item);
                })
                .catchError((fetchError) {
                  debugPrint(
                    '$connectivityLogPrefix Error fetching object ${item.objectId} during batch save pre-fetch: $fetchError',
                  );
                }),
          );
        } else {
          itemsToSaveFinal.add(item);
        }
      }
      if (fetchFutures.isNotEmpty) {
        await Future.wait(fetchFutures);
      }
    } else {
      itemsToSaveFinal = itemsToSave;
    }

    // Now, save the final list using the efficient batch method
    if (itemsToSaveFinal.isNotEmpty) {
      try {
        final className = itemsToSaveFinal.first.parseClassName;
        await ParseObjectOffline.saveAllToLocalCache(
          className,
          itemsToSaveFinal,
        );
      } catch (e) {
        debugPrint(
          '$connectivityLogPrefix Error during batch save operation: $e',
        );
      }
    }

    stopwatch.stop();
    debugPrint(
      '$connectivityLogPrefix Finished batch save processing in ${stopwatch.elapsedMilliseconds}ms.',
    );
  }

  // --- Helper to Proactively Cache the Next Page ---
  Future<void> _proactivelyCacheNextPage(int pageNumberToCache) async {
    if (isOffline || !widget.offlineMode || !widget.pagination) return;

    debugPrint(
      '$connectivityLogPrefix Proactively caching page $pageNumberToCache...',
    );
    final skipCount = pageNumberToCache * widget.pageSize;
    final query = QueryBuilder<T>.copy(widget.query)
      ..setAmountToSkip(skipCount)
      ..setLimit(widget.pageSize);

    try {
      final response = await query.query();
      if (response.success && response.results != null) {
        final List<T> results = (response.results as List).cast<T>();
        if (results.isNotEmpty) {
          await _saveBatchToCache(results);
        } else {
          debugPrint(
            '$connectivityLogPrefix Proactive cache: Page $pageNumberToCache was empty.',
          );
        }
      } else {
        debugPrint(
          '$connectivityLogPrefix Proactive cache failed for page $pageNumberToCache: ${response.error?.message}',
        );
      }
    } catch (e) {
      debugPrint(
        '$connectivityLogPrefix Proactive cache exception for page $pageNumberToCache: $e',
      );
    }
  }

  /// Loads more data when pagination is enabled.
  ///
  /// Call this method when the user scrolls near the end of the list.
  /// Does nothing if offline, already loading, or no more data available.
  Future<void> loadMoreData() async {
    if (isOffline) {
      debugPrint('$connectivityLogPrefix Cannot load more data while offline.');
      return;
    }
    if (_loadMoreStatus == LoadMoreStatus.loading || !_hasMoreData) {
      return;
    }

    debugPrint('$connectivityLogPrefix Loading more data...');
    setState(() {
      _loadMoreStatus = LoadMoreStatus.loading;
    });

    List<T> itemsToCacheBatch = [];

    try {
      _currentPage++;
      final skipCount = _currentPage * widget.pageSize;
      final nextPageQuery = QueryBuilder<T>.copy(widget.query)
        ..setAmountToSkip(skipCount)
        ..setLimit(widget.pageSize);

      final parseResponse = await nextPageQuery.query();

      if (parseResponse.success) {
        // Success at the end of the list is "no more data" (handled below),
        // NOT an error. Some SDK responses return results == null at the
        // boundary, which previously fell through to the error branch.
        final List<T> results = parseResponse.results?.cast<T>() ?? <T>[];

        if (results.isEmpty) {
          setState(() {
            _loadMoreStatus = LoadMoreStatus.noMoreData;
            _hasMoreData = false;
          });
          return;
        }

        if (widget.offlineMode) {
          itemsToCacheBatch.addAll(results);
        }

        setState(() {
          _items.addAll(results);
          _loadMoreStatus = LoadMoreStatus.idle;
        });

        if (itemsToCacheBatch.isNotEmpty) {
          _saveBatchToCache(itemsToCacheBatch);
        }

        if (_hasMoreData) {
          _proactivelyCacheNextPage(_currentPage + 1);
        }
      } else {
        debugPrint(
          '$connectivityLogPrefix LoadMore Error: ${parseResponse.error?.message}',
        );
        setState(() {
          _loadMoreStatus = LoadMoreStatus.error;
        });
      }
    } catch (e) {
      debugPrint('$connectivityLogPrefix Error loading more data: $e');
      setState(() {
        _loadMoreStatus = LoadMoreStatus.error;
      });
    }
  }

  /// Refreshes the data by disposing the current live list and reloading.
  ///
  /// Use this method when implementing pull-to-refresh or manual refresh.
  /// Loads from cache if offline, otherwise from server.
  Future<void> refreshData() async {
    debugPrint('$connectivityLogPrefix Refreshing data...');
    disposeLiveList();

    if (isOffline) {
      debugPrint(
        '$connectivityLogPrefix Refreshing offline, loading from cache.',
      );
      await loadDataFromCache();
    } else {
      debugPrint(
        '$connectivityLogPrefix Refreshing online, loading from server.',
      );
      await loadDataFromServer();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _noDataNotifier,
      builder: (context, noData, child) {
        // Optimistic (pending) items merged ahead of the server-backed items.
        final List<T> optimistic = _visibleOptimisticItems();
        final int optCount = optimistic.length;

        // Determine loading state: only when online, the server list isn't ready
        // yet AND there's nothing cached OR optimistic to show. With
        // offline-first, cached rows render immediately (from _items).
        final bool showLoadingIndicator =
            !isOffline && _liveList == null && _items.isEmpty && optCount == 0;

        if (showLoadingIndicator) {
          return widget.listLoadingElement != null
              ? SliverToBoxAdapter(child: widget.listLoadingElement!)
              : const SliverToBoxAdapter(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(16.0),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                );
        } else if (noData && optCount == 0) {
          // Show empty state only when there are no server AND no optimistic
          // items (e.g. the very first message in a new conversation).
          return widget.queryEmptyElement != null
              ? SliverToBoxAdapter(child: widget.queryEmptyElement!)
              : const SliverToBoxAdapter(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('No data available'),
                    ),
                  ),
                );
        } else {
          return SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              // Index-based prefetch: start loading the next page as soon as an
              // item within [preloadItemThreshold] of the end is built, so the
              // user never scrolls into a blank/stutter waiting for the next
              // page. Deferred to after this frame since loadMoreData calls
              // setState.
              if (widget.pagination &&
                  _hasMoreData &&
                  _loadMoreStatus != LoadMoreStatus.loading &&
                  index >=
                      (optCount + _items.length) -
                          widget.preloadItemThreshold) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) loadMoreData();
                });
              }

              // Optimistic items occupy the first [optCount] slots.
              if (index < optCount) {
                final T optItem = optimistic[index];
                return ParseLiveListElementWidget<T>(
                  key: ValueKey<String>(
                    'optimistic-${_optimisticKeyOf(optItem) ?? optItem.objectId ?? optItem.hashCode}',
                  ),
                  loadedData: () => optItem,
                  preLoadedData: () => optItem,
                  isOptimistic: true,
                  sizeFactor: const AlwaysStoppedAnimation<double>(1.0),
                  duration: widget.duration,
                  childBuilder:
                      widget.childBuilder ??
                      ParseLiveSliverListWidget.defaultChildBuilder,
                  index: index,
                );
              }

              final int realIndex = index - optCount;
              final item = _items[realIndex];
              StreamGetter<T>? itemStream;
              DataGetter<T>? loadedData;
              DataGetter<T>? preLoadedData;

              final liveList = _liveList;
              if (liveList != null && realIndex < liveList.size) {
                itemStream = () => liveList.getAt(realIndex);
                loadedData = () => liveList.getLoadedAt(realIndex);
                preLoadedData = () => liveList.getPreLoadedAt(realIndex);
              } else {
                loadedData = () => item;
                preLoadedData = () => item;
              }

              return ParseLiveListElementWidget<T>(
                key: ValueKey<String>(
                  item.objectId ?? 'unknown-$realIndex-${item.hashCode}',
                ),
                stream: itemStream,
                loadedData: loadedData,
                preLoadedData: preLoadedData,
                sizeFactor: const AlwaysStoppedAnimation<double>(1.0),
                duration: widget.duration,
                childBuilder:
                    widget.childBuilder ??
                    ParseLiveSliverListWidget.defaultChildBuilder,
                index: index,
              );
            }, childCount: optCount + _items.length),
          );
        }
      },
    );
  }

  @override
  void dispose() {
    disposeConnectivityHandler();
    widget.optimisticItems?.removeListener(_onOptimisticChanged);
    _liveList?.dispose();
    _noDataNotifier.dispose();
    super.dispose();
  }
}
