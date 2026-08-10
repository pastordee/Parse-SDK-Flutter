part of 'package:parse_server_sdk_flutter/parse_server_sdk_flutter.dart';

/// A widget that displays a live list of Parse objects in a PageView.
class ParseLiveListPageView<T extends sdk.ParseObject> extends StatefulWidget {
  const ParseLiveListPageView({
    super.key,
    required this.query,
    this.listLoadingElement,
    this.queryEmptyElement,
    this.duration = const Duration(milliseconds: 300),
    this.pageController,
    this.scrollPhysics,
    this.childBuilder,
    this.onPageChanged,
    this.scrollDirection,
    this.listenOnAllSubItems,
    this.listeningIncludes,
    this.lazyLoading = false,
    this.preloadedColumns,
    this.excludedColumns,
    this.pagination = false,
    this.pageSize = 100,
    this.paginationThreshold = 3,
    this.preloadItemThreshold = 5,
    this.loadingIndicator,
    this.cacheSize = 50,
    this.offlineMode = false, // Added offlineMode
    this.cacheFilter,
    this.cacheComparator,
    this.optimisticItems,
    this.optimisticKeyField,
    this.onOptimisticResolved,
    required this.fromJson, // Added fromJson
  });

  final sdk.QueryBuilder<T> query;
  final Widget? listLoadingElement;
  final Widget? queryEmptyElement;
  final Duration duration;
  final PageController? pageController;
  final ScrollPhysics? scrollPhysics;
  final Axis? scrollDirection;
  final ChildBuilder<T>? childBuilder;
  final void Function(int)? onPageChanged;

  final bool? listenOnAllSubItems;
  final List<String>? listeningIncludes;

  final bool lazyLoading;
  final List<String>? preloadedColumns;
  final List<String>? excludedColumns;

  // Pagination properties
  final bool pagination;
  final int pageSize;
  final int paginationThreshold;

  /// How many items from the end of the list to begin prefetching the next page.
  /// Index-based (item-height-independent) so infinite scroll stays smooth: as
  /// soon as an item within this many rows of the end is built, the next page
  /// starts loading in the background instead of waiting until the very bottom.
  final int preloadItemThreshold;
  final Widget? loadingIndicator;

  final int cacheSize;
  final bool offlineMode; // Added offlineMode

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

  final T Function(Map<String, dynamic> json) fromJson; // Added fromJson

  @override
  State<ParseLiveListPageView<T>> createState() =>
      _ParseLiveListPageViewState<T>();
}

class _ParseLiveListPageViewState<T extends sdk.ParseObject>
    extends State<ParseLiveListPageView<T>>
    with ConnectivityHandlerMixin<ParseLiveListPageView<T>> {
  CachedParseLiveList<T>? _liveList;
  final ValueNotifier<bool> _noDataNotifier = ValueNotifier<bool>(true);
  final List<T> _items = <T>[]; // Local list to manage all items

  // Pagination state
  bool _isLoadingMore = false;
  int _currentPage = 0;
  bool _hasMoreData = true;
  late PageController _pageController;

  // --- Implement Mixin Requirements ---
  @override
  Future<void> loadDataFromServer() => _loadData();

  @override
  Future<void> loadDataFromCache() => _loadFromCache();

  @override
  void disposeLiveList() {
    _liveList?.dispose();
    _liveList = null;
  }

  @override
  String get connectivityLogPrefix => 'ParseLivePageView';

  @override
  bool get isOfflineModeEnabled => widget.offlineMode;
  // --- End Mixin Requirements ---

  @override
  void initState() {
    super.initState();
    _pageController = widget.pageController ?? PageController();

    // Initialize connectivity and load initial data
    initConnectivityHandler(); // Replaces direct _loadData() call

    // Add listener to detect when to load more pages (only if online)
    if (widget.pagination) {
      _pageController.addListener(_checkForMoreData);
    }

    // Rebuild when the caller mutates its optimistic list.
    widget.optimisticItems?.addListener(_onOptimisticChanged);
  }

  @override
  void didUpdateWidget(covariant ParseLiveListPageView<T> oldWidget) {
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

  void _checkForMoreData() {
    // Only check/load more if online
    if (isOffline || !widget.pagination || _isLoadingMore || !_hasMoreData) {
      return;
    }

    // If we're within the threshold of the end, load more data
    if (_pageController.page != null &&
        _items.isNotEmpty &&
        _pageController.page! >= _items.length - widget.paginationThreshold) {
      _loadMoreData();
    }

    // Preload adjacent pages (lazy loading)
    if (_pageController.page != null && widget.lazyLoading) {
      int currentPage = _pageController.page!.round();
      _preloadAdjacentPages(currentPage);
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

    debugPrint('$connectivityLogPrefix Loading PageView data from cache...');
    _items.clear();

    try {
      final cached = await ParseObjectOffline.loadAllFromLocalCache(
        widget.query.object.parseClassName,
        where: widget.cacheFilter,
      );
      for (final obj in cached) {
        try {
          _items.add(widget.fromJson(obj.toJson(full: true)));
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
      debugPrint(
        '$connectivityLogPrefix Error loading PageView data from cache: $e',
      );
    }

    _noDataNotifier.value = _items.isEmpty;
    if (mounted) {
      setState(() {});
    }
  }

  /// Loads the data for the live list.
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
    debugPrint(
      '$connectivityLogPrefix Loading initial PageView data from server...',
    );
    List<T> itemsToCacheBatch = []; // Prepare list for batch caching

    try {
      // Reset state
      _currentPage = 0;
      _hasMoreData = true;
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
      final initialQuery = QueryBuilder<T>.copy(widget.query)
        ..setAmountToSkip(0)
        ..setLimit(widget.pageSize);

      // Fetch from server using ParseLiveList
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
          final item = liveList.getPreLoadedAt(i);
          if (item != null) {
            serverItems.add(item);
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
      if (_hasMoreData) {
        // Only if initial load wasn't empty
        _proactivelyCacheNextPage(1); // Start caching page 1 (index 1)
      }
      // --- End Proactive Cache Trigger ---

      // --- Stream Listener ---
      liveList.stream.listen(
        (event) {
          if (!mounted) return;

          T? objectToCache;

          try {
            // Wrap event processing
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
      if (mounted) setState(() {});
    }
  }

  /// Loads more data when approaching the end of available pages
  Future<void> _loadMoreData() async {
    // Prevent loading more if offline, already loading, or no more data
    if (isOffline) {
      debugPrint('$connectivityLogPrefix Cannot load more data while offline.');
      return;
    }
    if (_isLoadingMore || !_hasMoreData) return;

    debugPrint('$connectivityLogPrefix PageView loading more data...');
    setState(() {
      _isLoadingMore = true;
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
        // Success at the end of the list is "no more data" (handled below),
        // NOT an error. Some SDK responses return results == null at the
        // boundary, which previously fell through to the error branch.
        final List<T> results = parseResponse.results?.cast<T>() ?? <T>[];

        if (results.isEmpty) {
          setState(() {
            _hasMoreData = false;
          });
        } else {
          // Collect fetched items for caching if offline mode is on
          if (widget.offlineMode) {
            itemsToCacheBatch.addAll(results);
          }

          // --- Update UI FIRST ---
          setState(() {
            _items.addAll(results);
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
            _proactivelyCacheNextPage(
              _currentPage + 1,
            ); // Start caching page N+1
          }
          // --- End Proactive Cache Trigger ---
        }
      } else {
        // Handle error
        debugPrint(
          '$connectivityLogPrefix Error loading more data: ${parseResponse.error?.message}',
        );
        // Optionally set an error state or retry mechanism
      }
    } catch (e) {
      debugPrint('$connectivityLogPrefix Error loading more data: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
        });
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
        // If lazy loading is enabled, assume the item might need fetching before caching.
        // Add a future that fetches the item and then adds it to the final list.
        // The `fetch()` method should ideally handle cases where data is already present efficiently.
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
                // Decide whether to add the item even if fetch failed.
                // Current behavior: Only add successfully fetched items.
                // To add even on error (potentially partial data): itemsToSaveFinal.add(item);
              }),
        );
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

  /// Refreshes the data for the live list.
  Future<void> _refreshData() async {
    debugPrint('$connectivityLogPrefix Refreshing PageView data...');
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
      await loadDataFromServer(); // Calls the updated _loadData
    }
  }

  /// Preloads adjacent pages for smoother transitions
  void _preloadAdjacentPages(int currentIndex) {
    // Only preload if online and lazy loading is enabled
    if (isOffline || !widget.lazyLoading || _liveList == null) return;

    // Preload current page and next 2-3 pages
    final startIdx = max(0, currentIndex - 1);
    final endIdx = min(_items.length - 1, currentIndex + 3);

    for (int i = startIdx; i <= endIdx; i++) {
      if (i < _liveList!.size) {
        // This triggers lazy loading of these pages via CachedParseLiveList
        _liveList!.getAt(i);
      }
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

        // Determine loading state: Online AND _liveList not yet initialized AND
        // there's nothing cached OR optimistic to show.
        final bool showLoadingIndicator =
            !isOffline && _liveList == null && _items.isEmpty && optCount == 0;

        if (showLoadingIndicator) {
          return widget.listLoadingElement ??
              const Center(child: CircularProgressIndicator());
        }

        if (noData && optCount == 0) {
          return widget.queryEmptyElement ??
              const Center(child: Text('No data available'));
        }

        return RefreshIndicator(
          onRefresh: _refreshData,
          child: Stack(
            children: [
              PageView.builder(
                controller: _pageController,
                scrollDirection: widget.scrollDirection ?? Axis.horizontal,
                // Default to bouncing overscroll so reaching the first/last page
                // springs back. Callers can override via scrollPhysics.
                physics:
                    widget.scrollPhysics ??
                    const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                // Add optCount for optimistic items ahead of the list, plus 1
                // for the loading indicator if paginating and more data exists.
                itemCount:
                    optCount +
                    _items.length +
                    (widget.pagination && _hasMoreData ? 1 : 0),
                onPageChanged: (index) {
                  // Optimistic items occupy the first [optCount] slots; map the
                  // page index back onto the server-backed list.
                  final int realIndex = index - optCount;

                  // Preload adjacent pages when page changes (only if online)
                  if (!isOffline && widget.lazyLoading && realIndex >= 0) {
                    _preloadAdjacentPages(realIndex);
                  }

                  // Check if we need to load more data (only if online)
                  if (!isOffline &&
                      widget.pagination &&
                      _hasMoreData &&
                      realIndex >= _items.length - widget.paginationThreshold) {
                    _loadMoreData();
                  }

                  // Call the original onPageChanged callback
                  widget.onPageChanged?.call(index);
                },
                itemBuilder: (context, index) {
                  // Index-based prefetch: start loading the next page as soon as
                  // an item within [preloadItemThreshold] of the end is built, so
                  // the user never swipes into a blank/stutter waiting for the
                  // next page. Deferred to after this frame since _loadMoreData
                  // calls setState.
                  if (widget.pagination &&
                      _hasMoreData &&
                      !_isLoadingMore &&
                      index >=
                          (optCount + _items.length) -
                              widget.preloadItemThreshold) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _loadMoreData();
                    });
                  }

                  // Show loading indicator for the last item if paginating and
                  // more data is available.
                  if (widget.pagination && index >= optCount + _items.length) {
                    return widget.loadingIndicator ??
                        const Center(child: CircularProgressIndicator());
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
                          ParseLiveListWidget.defaultChildBuilder,
                      index: index,
                    );
                  }

                  final int realIndex = index - optCount;

                  // Preload adjacent pages for smoother experience (only if online)
                  if (!isOffline) {
                    _preloadAdjacentPages(realIndex);
                  }

                  final item = _items[realIndex];

                  StreamGetter<T>? itemStream;
                  DataGetter<T>? loadedData;
                  DataGetter<T>? preLoadedData;

                  final liveList = _liveList;
                  // Use liveList data only if online, lazy loading, and within bounds
                  if (!isOffline &&
                      liveList != null &&
                      realIndex < liveList.size &&
                      widget.lazyLoading) {
                    itemStream = () => liveList.getAt(realIndex);
                    loadedData = () => liveList.getLoadedAt(realIndex);
                    preLoadedData = () => liveList.getPreLoadedAt(realIndex);
                  } else {
                    // Offline or not lazy loading: Use data directly from _items
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
                        ParseLiveListWidget.defaultChildBuilder,
                    index: index,
                  );
                },
              ),
              // Show loading indicator overlay when loading more pages
              if (_isLoadingMore)
                Positioned(
                  bottom: 20,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child:
                          widget.loadingIndicator ??
                          const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    disposeConnectivityHandler(); // Dispose mixin resources
    disposeLiveList(); // Dispose live list
    _noDataNotifier.dispose();

    widget.optimisticItems?.removeListener(_onOptimisticChanged);

    // Remove listener only if we added it
    if (widget.pagination && widget.pageController == null) {
      _pageController.removeListener(_checkForMoreData);
    }
    // Dispose controller only if we created it
    if (widget.pageController == null) {
      _pageController.dispose();
    }
    super.dispose();
  }
}

// --- ParseLiveListElementWidget remains unchanged ---
// (Should be identical to the one in parse_live_list.dart)
// class ParseLiveListElementWidget<T extends sdk.ParseObject> extends StatefulWidget { ... }
// class _ParseLiveListElementWidgetState<T extends sdk.ParseObject> extends State<ParseLiveListElementWidget<T>> { ... }
