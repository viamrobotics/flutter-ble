import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Wraps a publicly exposed [StreamController] as a way to forward
// methods for [IOSink].
mixin IOSinkFromControllerMixin implements IOSink {
  /// All writes should go to this controller's sink.
  // see close
  // ignore: close_sinks
  final StreamController<List<int>> ioSinkController = StreamController<List<int>>();

  final Encoding _encoding = utf8;

  @override
  Encoding get encoding => _encoding;

  @override
  set encoding(Encoding value) {
    throw StateError('IOSink encoding is not mutable');
  }

  @override
  void add(List<int> data) {
    ioSinkController.sink.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    ioSinkController.sink.addError(error, stackTrace);
  }

  @override
  Future addStream(Stream<List<int>> stream) {
    return ioSinkController.sink.addStream(stream);
  }

  @override
  Future close() {
    return ioSinkController.sink.close();
  }

  @override
  Future get done => ioSinkController.sink.done;

  @override
  Future flush() {
    return Future.value(this);
  }

  @override
  void write(Object? object) {
    final String string = '$object';
    if (string.isEmpty) return;
    add(_encoding.encode(string));
  }

  @override
  void writeAll(Iterable objects, [String separator = '']) {
    final Iterator iterator = objects.iterator;
    if (!iterator.moveNext()) return;
    if (separator.isEmpty) {
      do {
        write(iterator.current);
      } while (iterator.moveNext());
    } else {
      write(iterator.current);
      while (iterator.moveNext()) {
        write(separator);
        write(iterator.current);
      }
    }
  }

  @override
  void writeCharCode(int charCode) {
    write(String.fromCharCode(charCode));
  }

  @override
  void writeln([Object? object = '']) {
    write(object);
    write('\n');
  }
}

/// Wraps a publicly exposed [StreamController] as a way to forward
// methods for [Stream].
mixin StreamFromControllerMixin<T> implements Stream<T> {
  /// All reads should go to this controller's stream.
  // see usage of mixin for closes
  // ignore: close_sinks
  final StreamController<T> streamController = StreamController<T>();

  @override
  Future<bool> any(bool Function(T element) test) {
    return streamController.stream.any(test);
  }

  @override
  Stream<T> asBroadcastStream(
      {void Function(StreamSubscription<T> subscription)? onListen, void Function(StreamSubscription<T> subscription)? onCancel}) {
    return streamController.stream.asBroadcastStream(onListen: onListen, onCancel: onCancel);
  }

  @override
  Stream<E> asyncExpand<E>(Stream<E>? Function(T event) convert) {
    return streamController.stream.asyncExpand(convert);
  }

  @override
  Stream<E> asyncMap<E>(FutureOr<E> Function(T event) convert) {
    return streamController.stream.asyncMap(convert);
  }

  @override
  Stream<R> cast<R>() {
    return streamController.stream.cast<R>();
  }

  @override
  Future<bool> contains(Object? needle) {
    return streamController.stream.contains(needle);
  }

  @override
  Stream<T> distinct([bool Function(T previous, T next)? equals]) {
    return streamController.stream.distinct(equals);
  }

  @override
  Future<E> drain<E>([E? futureValue]) {
    return streamController.stream.drain<E>(futureValue);
  }

  @override
  Future<T> elementAt(int index) {
    return streamController.stream.elementAt(index);
  }

  @override
  Future<bool> every(bool Function(T element) test) {
    return streamController.stream.every(test);
  }

  @override
  Stream<S> expand<S>(Iterable<S> Function(T element) convert) {
    return streamController.stream.expand(convert);
  }

  @override
  Future<T> get first {
    return streamController.stream.first;
  }

  @override
  Future<T> firstWhere(bool Function(T element) test, {T Function()? orElse}) {
    return streamController.stream.firstWhere(test, orElse: orElse);
  }

  @override
  Future<S> fold<S>(S initialValue, S Function(S previous, T element) combine) {
    return streamController.stream.fold(initialValue, combine);
  }

  @override
  Future<void> forEach(void Function(T element) action) {
    return streamController.stream.forEach(action);
  }

  @override
  Stream<T> handleError(Function onError, {bool Function(dynamic error)? test}) {
    return streamController.stream.handleError(onError, test: test);
  }

  @override
  bool get isBroadcast {
    return streamController.stream.isBroadcast;
  }

  @override
  Future<bool> get isEmpty {
    return streamController.stream.isEmpty;
  }

  @override
  Future<String> join([String separator = '']) {
    return streamController.stream.join(separator);
  }

  @override
  Future<T> get last {
    return streamController.stream.last;
  }

  @override
  Future<T> lastWhere(bool Function(T element) test, {T Function()? orElse}) {
    return streamController.stream.lastWhere(test, orElse: orElse);
  }

  @override
  Future<int> get length {
    return streamController.stream.length;
  }

  @override
  StreamSubscription<T> listen(void Function(T event)? onData, {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return streamController.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  Stream<S> map<S>(S Function(T event) convert) {
    return streamController.stream.map<S>(convert);
  }

  @override
  Future pipe(StreamConsumer<T> streamConsumer) {
    return streamController.stream.pipe(streamConsumer);
  }

  @override
  Future<T> reduce(T Function(T previous, T element) combine) {
    return streamController.stream.reduce(combine);
  }

  @override
  Future<T> get single {
    return streamController.stream.single;
  }

  @override
  Future<T> singleWhere(bool Function(T element) test, {T Function()? orElse}) {
    return streamController.stream.singleWhere(test, orElse: orElse);
  }

  @override
  Stream<T> skip(int count) {
    return streamController.stream.skip(count);
  }

  @override
  Stream<T> skipWhile(bool Function(T element) test) {
    return streamController.stream.skipWhile(test);
  }

  @override
  Stream<T> take(int count) {
    return streamController.stream.take(count);
  }

  @override
  Stream<T> takeWhile(bool Function(T element) test) {
    return streamController.stream.takeWhile(test);
  }

  @override
  Stream<T> timeout(Duration timeLimit, {void Function(EventSink<T> sink)? onTimeout}) {
    return streamController.stream.timeout(timeLimit, onTimeout: onTimeout);
  }

  @override
  Future<List<T>> toList() {
    return streamController.stream.toList();
  }

  @override
  Future<Set<T>> toSet() {
    return streamController.stream.toSet();
  }

  @override
  Stream<S> transform<S>(StreamTransformer<T, S> streamTransformer) {
    return streamController.stream.transform<S>(streamTransformer);
  }

  @override
  Stream<T> where(bool Function(T event) test) {
    return streamController.stream.where(test);
  }
}
