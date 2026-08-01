part of 'package:parse_server_sdk_flutter/parse_server_sdk_flutter.dart';

/// The type of function that builds a child widget for a ParseLiveList element.
typedef ChildBuilder<T extends sdk.ParseObject> =
    Widget Function(
      BuildContext context,
      sdk.ParseLiveListElementSnapshot<T> snapshot, [
      int? index,
    ]);

/// The type of function that returns the stream to listen for updates from.
typedef StreamGetter<T extends sdk.ParseObject> = Stream<T> Function();

/// The type of function that returns the loaded data for a ParseLiveList element.
typedef DataGetter<T extends sdk.ParseObject> = T? Function();

/// Represents the status of the load more operation
enum LoadMoreStatus { idle, loading, noMoreData, error }

/// Footer builder for pagination
typedef FooterBuilder =
    Widget Function(BuildContext context, LoadMoreStatus loadMoreStatus);

/// Builds a [Comparator] from a query's `order` limiter (e.g. `-createdAt` or
/// `runCount,-createdAt`) so cached rows render in the SAME order as the server
/// query while offline. The offline store is an unordered map, so without this
/// a newly-cached item (inserted last) sinks to the bottom of the list until the
/// server load re-sorts — which reads as "the new item isn't cached".
///
/// Returns null when the query has no usable `order` limiter, in which case the
/// caller should leave the cached order as-is.
Comparator<T>? cacheOrderComparatorFromQuery<T extends sdk.ParseObject>(
  sdk.QueryBuilder query,
) {
  final Object? orderRaw = query.limiters['order'];
  if (orderRaw is! String || orderRaw.isEmpty) return null;
  final List<String> keys =
      orderRaw.split(',').where((String k) => k.isNotEmpty).toList();
  if (keys.isEmpty) return null;
  return (T a, T b) {
    for (final String rawKey in keys) {
      final bool descending = rawKey.startsWith('-');
      final String key = descending ? rawKey.substring(1) : rawKey;
      final Object? av = _orderFieldValue(a, key);
      final Object? bv = _orderFieldValue(b, key);
      int cmp;
      if (av == null && bv == null) {
        cmp = 0;
      } else if (av == null) {
        cmp = -1; // nulls sort first (ascending); flipped below when descending
      } else if (bv == null) {
        cmp = 1;
      } else if (av is Comparable && bv is Comparable) {
        try {
          cmp = Comparable.compare(av, bv);
        } catch (_) {
          cmp = 0; // incomparable types — treat as equal
        }
      } else {
        cmp = 0;
      }
      if (cmp != 0) return descending ? -cmp : cmp;
    }
    return 0;
  };
}

/// Reads the value used for offline ordering. `createdAt`/`updatedAt` come from
/// the object's timestamp getters (not stored in the field map); everything else
/// is read from the field map.
Object? _orderFieldValue(sdk.ParseObject obj, String key) {
  switch (key) {
    case 'createdAt':
      return obj.createdAt;
    case 'updatedAt':
      return obj.updatedAt;
    default:
      return obj.get<Object?>(key);
  }
}

/// A widget that displays a live list of Parse objects.
class ParseLiveListWidget<T extends sdk.ParseObject> extends StatefulWidget {
  const ParseLiveListWidget({
    super.key,
    required this.query,
    this.listLoadingElement,
    this.queryEmptyElement,
    this.duration = const Duration(milliseconds: 300),
    this.scrollPhysics,
    this.scrollController,
    this.scrollDirection = Axis.vertical,
    this.padding,
    this.primary,
    this.reverse = false,
    this.childBuilder,
    this.shrinkWrap = false,
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
    this.loadMoreOffset = 200.0,
    this.preloadItemThreshold = 5,
    this.cacheSize = 50,
    this.offlineMode = false,
    this.cacheFilter,
    this.cacheComparator,
    required this.fromJson,
  });

  final sdk.QueryBuilder<T> query;
  final Widget? listLoadingElement;
  final Widget? queryEmptyElement;
  final Duration duration;
  final ScrollPhysics? scrollPhysics;
  final ScrollController? scrollController;

  final Axis scrollDirection;
  final EdgeInsetsGeometry? padding;
  final bool? primary;
  final bool reverse;
  final bool shrinkWrap;

  final ChildBuilder<T>? childBuilder;
  final ChildBuilder<T>?
  removedItemBuilder; // Note: removedItemBuilder is not currently used in the state logic

  final bool? listenOnAllSubItems;
  final List<String>? listeningIncludes;

  final bool lazyLoading;
  final List<String>? preloadedColumns;
  final List<String>? excludedColumns;

  final bool pagination;
  final Widget? paginationLoadingElement;
  final FooterBuilder? footerBuilder;
  final double loadMoreOffset;

  /// How many items from the end of the list to begin prefetching the next page.
  /// Index-based (item-height-independent) so infinite scroll stays smooth: as
  /// soon as an item within this many rows of the end is built, the next page
  /// starts loading in the background instead of waiting until the very bottom.
  final int preloadItemThreshold;
  final int pageSize;
  final int nonPaginatedLimit;
  final int cacheSize;
  final bool offlineMode;

  /// Optional predicate to scope offline-cached items to this query. The offline
  /// store keeps one bucket per class, so a per-query list (e.g. one chat
  /// conversation) must pass this or it would render unrelated cached rows.
  /// Applied inside [ParseObjectOffline.loadAllFromLocalCache].
  final bool Function(sdk.ParseObject object)? cacheFilter;

  /// Optional comparator to order offline-cached items to match the query's sort
  /// (the offline store has no inherent order). Applied only to the cached
  /// render; the subsequent server load reconciles the final order.
  final int Function(T a, T b)? cacheComparator;

  final T Function(Map<String, dynamic> json) fromJson;

  @override
  State<ParseLiveListWidget<T>> createState() => _ParseLiveListWidgetState<T>();

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

class _ParseLiveListWidgetState<T extends sdk.ParseObject>
    extends State<ParseLiveListWidget<T>>
    with ConnectivityHandlerMixin<ParseLiveListWidget<T>> {
  CachedParseLiveList<T>? _liveList;
  final ValueNotifier<bool> _noDataNotifier = ValueNotifier<bool>(true);
  final List<T> _items = <T>[];

  late final ScrollController _scrollController;
  LoadMoreStatus _loadMoreStatus = LoadMoreStatus.idle;
  int _currentPage = 0;
  bool _hasMoreData = true;

  @override
  String get connectivityLogPrefix => 'ParseLiveListWidget';

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

    // Initialize ScrollController
    if (widget.scrollController == null) {
      _scrollController = ScrollController();
    } else {
      // Use provided controller, but ensure it's the one we listen to if pagination is on
      _scrollController = widget.scrollController!;
    }

    // Add listener only if pagination is enabled and we own the controller or are using the provided one
    if (widget.pagination) {
      _scrollController.addListener(_onScroll);
    }

    // Initialize connectivity and load initial data
    initConnectivityHandler();
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

    final List<T> loaded = <T>[];
    try {
      // Scope to this query via cacheFilter so a per-conversation list doesn't
      // pull in every cached object of the class.
      final cached = await ParseObjectOffline.loadAllFromLocalCache(
        widget.query.object.parseClassName,
        where: widget.cacheFilter,
      );
      for (final obj in cached) {
        try {
          loaded.add(widget.fromJson(obj.toJson(full: true)));
        } catch (e) {
          debugPrint(
            '$connectivityLogPrefix Error deserializing cached object: $e',
          );
        }
      }
      // Order the cached render to match the query's sort (the store is
      // unordered). The server load reconciles the final order shortly after.
      if (widget.cacheComparator != null) {
        loaded.sort(widget.cacheComparator);
      } else {
        // No explicit comparator — fall back to the query's own order so newly
        // cached items land in their correct spot (e.g. -createdAt = newest on
        // top) instead of at the bottom in cache-insertion order.
        final Comparator<T>? auto =
            cacheOrderComparatorFromQuery<T>(widget.query);
        if (auto != null) loaded.sort(auto);
      }
      debugPrint(
        '$connectivityLogPrefix Loaded ${loaded.length} items from cache for ${widget.query.object.parseClassName}',
      );
      // Diagnostic: show the order limiter used and the first few rows so it's
      // clear whether the newest items are in the cache and sorted to the top.
      if (loaded.isNotEmpty) {
        final Object? orderLimiter = widget.query.limiters['order'];
        final preview = loaded
            .take(3)
            .map((e) => '${e.objectId}@${(e).createdAt?.toIso8601String()}')
            .join(', ');
        debugPrint(
          '$connectivityLogPrefix Cache order="$orderLimiter" top3=[$preview]',
        );
      }
    } catch (e) {
      debugPrint('$connectivityLogPrefix Error loading data from cache: $e');
    }

    _items
      ..clear()
      ..addAll(loaded);
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

    // OFFLINE-FIRST: render cached rows immediately (scoped via cacheFilter) so
    // the list is populated while the server query runs in the background — no
    // loading spinner or blank wait on entry. The server results below then
    // reconcile (replace) these once they arrive.
    if (widget.offlineMode && _items.isEmpty) {
      await _loadFromCache();
    }

    try {
      // Reset pagination and state
      if (widget.pagination) {
        _currentPage = 0;
        _loadMoreStatus = LoadMoreStatus.idle;
        _hasMoreData = true;
      }
      // Keep cached rows on screen while fetching; only flip to the empty/
      // loading state when there is nothing cached to show.
      if (_items.isEmpty) {
        _noDataNotifier.value = true;
        if (mounted) setState(() {}); // Show loading state immediately
      }

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

      // Build the fresh list from server, then swap it in atomically so the
      // cached rows shown above are replaced without a blank frame (same
      // objectIds keep their element/scroll position via the ValueKey).
      final List<T> serverItems = <T>[];
      int nullPreloaded = 0;
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
          } else {
            // Lazy loading: an index outside the preload window returns null and
            // gets dropped from BOTH the display list and the cache batch.
            nullPreloaded++;
          }
        }
      }
      // Diagnostic: compare server results to the cache. If serverTop3 shows
      // recent items that the cache top3 lacks, the batch save is dropping them
      // (nullPreloaded > 0 points at the lazy preload window as the cause).
      if (widget.offlineMode) {
        final serverPreview = serverItems
            .take(3)
            .map((e) => '${e.objectId}@${e.createdAt?.toIso8601String()}')
            .join(', ');
        debugPrint(
          '$connectivityLogPrefix Server liveList.size=${liveList.size} '
          'nonNull=${serverItems.length} nullPreloaded=$nullPreloaded '
          'toCache=${itemsToCacheBatch.length} serverTop3=[$serverPreview]',
        );
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

      // --- Trigger Background Batch Cache AFTER UI update ---
      if (itemsToCacheBatch.isNotEmpty) {
        // Don't await, let it run in background
        _saveBatchToCache(itemsToCacheBatch);
      }
      // --- End Trigger ---

      // --- Stream Listener ---
      liveList.stream.listen(
        (event) {
          if (!mounted) return; // Avoid processing if widget is disposed

          T? objectToCache; // For single item cache updates from stream

          try {
            // Wrap event processing in try-catch
            if (event is sdk.ParseLiveListAddEvent<sdk.ParseObject>) {
              // Cast to T — stream events carry ParseObject but _items is List<T>
              final addedItem = event.object as T;
              setState(() {
                _items.insert(event.index, addedItem);
              });
              objectToCache = addedItem;
            } else if (event is sdk.ParseLiveListDeleteEvent<sdk.ParseObject>) {
              if (event.index >= 0 && event.index < _items.length) {
                final removedItem = _items.removeAt(event.index);
                setState(() {});
                if (widget.offlineMode) {
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
              // Cast to T — same reason as AddEvent above
              final updatedItem = event.object as T;
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
              // Fetch might be needed if stream update is partial and lazy loading is on
              // For simplicity, assuming stream provides complete object or fetch isn't critical here
              objectToCache.saveToLocalCache().catchError((e) {
                debugPrint(
                  '$connectivityLogPrefix Error saving stream update for ${objectToCache?.objectId} to cache: $e',
                );
              });
            }

            _noDataNotifier.value = _items.isEmpty;
          } catch (e) {
            debugPrint(
              '$connectivityLogPrefix Error processing stream event: $e',
            );
            // Optionally update state to reflect error
          }
        },
        onError: (error) {
          debugPrint('$connectivityLogPrefix LiveList Stream Error: $error');
          // Optionally handle stream errors (e.g., show error message)
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
        // Check if a key typically set by the server (like updatedAt) is missing,
        // indicating the object might need fetching.
        if (!item.containsKey(sdk.keyVarUpdatedAt)) {
          // Collect fetch futures to run concurrently
          fetchFutures.add(
            item
                .fetch()
                .then((_) {
                  // Add successfully fetched items to the final list
                  itemsToSaveFinal.add(item);
                })
                .catchError((fetchError) {
                  debugPrint(
                    '$connectivityLogPrefix Error fetching object ${item.objectId} during batch save pre-fetch: $fetchError',
                  );
                  // Optionally add partially loaded item anyway? itemsToSaveFinal.add(item);
                }),
          );
        } else {
          // Item data is already available, add directly
          itemsToSaveFinal.add(item);
        }
      }
      // Wait for all necessary fetches to complete
      if (fetchFutures.isNotEmpty) {
        await Future.wait(fetchFutures);
      }
    } else {
      // Not lazy loading, just use the original list
      itemsToSaveFinal = itemsToSave;
    }

    // Now, save the final list (with fetched data if applicable) using the efficient batch method
    if (itemsToSaveFinal.isNotEmpty) {
      try {
        // Ensure we have the className, assuming all items are the same type
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
    // Adjust log message as the static method now prints details
    debugPrint(
      '$connectivityLogPrefix Finished batch save processing in ${stopwatch.elapsedMilliseconds}ms.',
    );
  }
  // --- End Helper ---

  // --- Helper to Proactively Cache the Next Page ---
  Future<void> _proactivelyCacheNextPage(int pageNumberToCache) async {
    // Only run if online, offline mode is on, and pagination is enabled
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
          // Use the existing batch save helper (it handles lazy fetching if needed)
          // Await is fine here as this whole function runs in the background
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
  // --- End Helper ---

  Future<void> _loadMoreData() async {
    // Prevent loading more if offline, already loading, or no more data
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

    List<T> itemsToCacheBatch = []; // Prepare list for batch caching

    try {
      _currentPage++;
      final skipCount = _currentPage * widget.pageSize;
      final nextPageQuery = QueryBuilder<T>.copy(widget.query)
        ..setAmountToSkip(skipCount)
        ..setLimit(widget.pageSize);

      // Fetch next page from server
      final parseResponse = await nextPageQuery.query();
      debugPrint(
        '$connectivityLogPrefix LoadMore Response: Success=${parseResponse.success}, Count=${parseResponse.count}, Results=${parseResponse.results?.length}, Error: ${parseResponse.error?.message}',
      );

      if (parseResponse.success) {
        // A SUCCESSFUL query at the end of the list is "no more data" (bounce
        // off), NOT an error. Some SDK responses return results == null (rather
        // than an empty list) at the boundary, which previously fell through to
        // the error branch and showed "Error loading more items".
        final List<T> results =
            parseResponse.results?.cast<T>() ?? <T>[];

        if (results.isEmpty) {
          setState(() {
            _loadMoreStatus = LoadMoreStatus.noMoreData;
            _hasMoreData = false;
          });
          return; // No more items found
        }

        // Collect fetched items for caching if offline mode is on
        if (widget.offlineMode) {
          itemsToCacheBatch.addAll(results);
        }

        // --- Update UI FIRST ---
        setState(() {
          _items.addAll(results);
          _loadMoreStatus = LoadMoreStatus.idle;
        });
        // --- End UI Update ---

        // --- Trigger Background Batch Cache AFTER UI update ---
        if (itemsToCacheBatch.isNotEmpty) {
          // Don't await, let it run in background
          _saveBatchToCache(itemsToCacheBatch);
        }
        // --- End Trigger ---

        // --- Trigger Proactive Cache for Next Page ---
        if (_hasMoreData) {
          // Check if the current load didn't signal the end
          _proactivelyCacheNextPage(_currentPage + 1); // Start caching page N+1
        }
        // --- End Proactive Cache Trigger ---
      } else {
        // Handle query failure
        debugPrint(
          '$connectivityLogPrefix LoadMore Error: ${parseResponse.error?.message}',
        );
        setState(() {
          _loadMoreStatus = LoadMoreStatus.error;
        });
      }
    } catch (e) {
      // Handle general error during load more
      debugPrint('$connectivityLogPrefix Error loading more data: $e');
      setState(() {
        _loadMoreStatus = LoadMoreStatus.error;
      });
    }
  }

  void _onScroll() {
    // Trigger load more only if online, not already loading, and has more data
    if (isOffline ||
        _loadMoreStatus == LoadMoreStatus.loading ||
        !_hasMoreData) {
      return;
    }

    // Check if scroll controller is attached and near the end
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    if (maxScroll - currentScroll <= widget.loadMoreOffset) {
      _loadMoreData();
    }
  }

  Future<void> _refreshData() async {
    debugPrint('$connectivityLogPrefix Refreshing data...');
    disposeLiveList(); // Dispose existing live list before refresh

    // Reload based on connectivity
    if (isOffline) {
      debugPrint(
        '$connectivityLogPrefix Refreshing offline, loading from cache.',
      );
      await loadDataFromCache();
    } else {
      debugPrint(
        '$connectivityLogPrefix Refreshing online, loading from server.',
      );
      await loadDataFromServer(); // This now calls the updated _loadData
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _noDataNotifier,
      builder: (context, noData, child) {
        // Determine loading state: only when online, the server list isn't ready
        // yet AND there's nothing cached to show. With offline-first, cached rows
        // render immediately (from _items) instead of a spinner.
        final bool showLoadingIndicator =
            !isOffline && _liveList == null && _items.isEmpty;

        if (showLoadingIndicator) {
          return widget.listLoadingElement ??
              const Center(child: CircularProgressIndicator());
        } else if (noData) {
          // Show empty state if not loading AND there are no items.
          return widget.queryEmptyElement ??
              const Center(child: Text('No data available'));
        } else {
          // Show the list if not loading and there are items.
          return RefreshIndicator(
            onRefresh: _refreshData,
            child: Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    // Default to bouncing overscroll so reaching either end of
                    // the list springs back — a no-label "you're at the end"
                    // signal (esp. after pagination stops). Callers can still
                    // override via scrollPhysics.
                    physics: widget.scrollPhysics ??
                        const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                    controller: _scrollController, // Use the state's controller
                    scrollDirection: widget.scrollDirection,
                    padding: widget.padding,
                    primary: widget.primary,
                    reverse: widget.reverse,
                    shrinkWrap: widget.shrinkWrap,
                    itemCount: _items.length,
                    itemBuilder: (context, index) {
                      // Index-based prefetch: start loading the next page as soon
                      // as an item within [preloadItemThreshold] of the end is
                      // built, so the user never scrolls into a blank/stutter
                      // waiting for the next page. Deferred to after this frame
                      // since _loadMoreData calls setState.
                      if (widget.pagination &&
                          _hasMoreData &&
                          _loadMoreStatus != LoadMoreStatus.loading &&
                          index >=
                              _items.length - widget.preloadItemThreshold) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) _loadMoreData();
                        });
                      }
                      final item = _items[index];
                      StreamGetter<T>? itemStream;
                      DataGetter<T>? loadedData;
                      DataGetter<T>? preLoadedData;

                      // Use _liveList ONLY if it's initialized (i.e., we are online and loaded)
                      final liveList = _liveList;
                      if (liveList != null && index < liveList.size) {
                        itemStream = () => liveList.getAt(index);
                        loadedData = () => liveList.getLoadedAt(index);
                        preLoadedData = () => liveList.getPreLoadedAt(index);
                      } else {
                        // Offline or before _liveList is ready: Use data directly from _items
                        loadedData = () => item;
                        preLoadedData = () => item;
                      }

                      return ParseLiveListElementWidget<T>(
                        key: ValueKey<String>(
                          item.objectId ?? 'unknown-$index-${item.hashCode}',
                        ), // Ensure unique key
                        stream: itemStream, // Will be null when offline
                        loadedData: loadedData,
                        preLoadedData: preLoadedData,
                        sizeFactor: const AlwaysStoppedAnimation<double>(
                          1.0,
                        ), // Assuming no animations for now
                        duration: widget.duration,
                        childBuilder:
                            widget.childBuilder ??
                            ParseLiveListWidget.defaultChildBuilder,
                        index: index,
                      );
                    },
                  ),
                ),
                // Show footer only if pagination is enabled and items exist
                if (widget.pagination && _items.isNotEmpty)
                  widget.footerBuilder != null
                      ? widget.footerBuilder!(context, _loadMoreStatus)
                      : _buildDefaultFooter(),
              ],
            ),
          );
        }
      },
    );
  }

  // Builds the default footer: a spinner ONLY while actively loading the next
  // page. Reaching the end (noMoreData), errors, and idle all render nothing —
  // the list just stops with no label, so the user sees the spinner and then it
  // quietly disappears.
  Widget _buildDefaultFooter() {
    if (_loadMoreStatus == LoadMoreStatus.loading) {
      return widget.paginationLoadingElement ??
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16.0),
            alignment: Alignment.center,
            child: const CircularProgressIndicator(),
          );
    }
    return const SizedBox.shrink();
  }

  @override
  void dispose() {
    disposeConnectivityHandler(); // Dispose mixin resources

    // Remove listener only if we added it
    if (widget.pagination && widget.scrollController == null) {
      _scrollController.removeListener(_onScroll);
    }
    // Dispose controller only if we created it
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }

    _liveList?.dispose(); // Dispose live list resources
    _noDataNotifier.dispose(); // Dispose value notifier
    super.dispose();
  }
}

// --- ParseLiveListElementWidget remains unchanged ---
class ParseLiveListElementWidget<T extends sdk.ParseObject>
    extends StatefulWidget {
  const ParseLiveListElementWidget({
    super.key,
    this.stream,
    this.loadedData,
    this.preLoadedData,
    required this.sizeFactor,
    required this.duration,
    required this.childBuilder,
    this.index,
    this.error,
  });

  final StreamGetter<T>? stream;
  final DataGetter<T>? loadedData;
  final DataGetter<T>? preLoadedData;
  final Animation<double> sizeFactor;
  final Duration duration;
  final ChildBuilder<T> childBuilder;
  final int? index;
  final ParseError?
  error; // Note: error parameter is not currently used in state logic

  bool get hasData => loadedData != null;

  @override
  State<ParseLiveListElementWidget<T>> createState() =>
      _ParseLiveListElementWidgetState<T>();
}

class _ParseLiveListElementWidgetState<T extends sdk.ParseObject>
    extends State<ParseLiveListElementWidget<T>> {
  late sdk.ParseLiveListElementSnapshot<T> _snapshot;
  StreamSubscription<T>? _streamSubscription;

  // Removed redundant getters, use widget directly or _snapshot
  // bool get hasData => widget.loadedData != null;
  // bool get failed => widget.error != null;

  @override
  void initState() {
    super.initState();
    // Initialize snapshot with potentially preloaded/loaded data
    _snapshot = sdk.ParseLiveListElementSnapshot<T>(
      loadedData: widget.loadedData?.call(),
      preLoadedData: widget.preLoadedData?.call(),
      error: widget.error, // Initialize with potential error passed in
    );

    // Subscribe to stream if provided
    if (widget.stream != null) {
      _streamSubscription = widget.stream!().listen(
        (data) {
          if (mounted) {
            // Check if widget is still in the tree
            setState(() {
              // Update snapshot with new data from stream
              _snapshot = sdk.ParseLiveListElementSnapshot<T>(
                loadedData: data,
                preLoadedData: _snapshot
                    .preLoadedData, // Keep original preLoadedData? Or update? Let's update.
                // preLoadedData: data,
              );
            });
          }
        },
        onError: (error) {
          if (mounted) {
            // Check if widget is still in the tree
            if (error is sdk.ParseError) {
              setState(() {
                // Update snapshot with error information
                _snapshot = sdk.ParseLiveListElementSnapshot<T>(
                  error: error,
                  preLoadedData:
                      _snapshot.preLoadedData, // Keep previous data on error?
                  loadedData: _snapshot.loadedData,
                );
              });
            } else {
              // Handle non-ParseError errors if necessary
              debugPrint('ParseLiveListElementWidget Stream Error: $error');
              setState(() {
                _snapshot = sdk.ParseLiveListElementSnapshot<T>(
                  error: sdk.ParseError(
                    message: error.toString(),
                  ), // Generic error
                  preLoadedData: _snapshot.preLoadedData,
                  loadedData: _snapshot.loadedData,
                );
              });
            }
          }
        },
      );
    }
  }

  @override
  void dispose() {
    _streamSubscription?.cancel(); // Cancel stream subscription
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Use SizeTransition for potential animations (though factor is currently fixed)
    return SizeTransition(
      sizeFactor: widget.sizeFactor,
      child: widget.index != null
          ? widget.childBuilder(context, _snapshot, widget.index)
          : widget.childBuilder(context, _snapshot),
    );
  }
}
