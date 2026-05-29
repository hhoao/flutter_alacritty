// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'event_proxy.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$EngineEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EngineEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EngineEvent()';
}


}

/// @nodoc
class $EngineEventCopyWith<$Res>  {
$EngineEventCopyWith(EngineEvent _, $Res Function(EngineEvent) __);
}


/// Adds pattern-matching-related methods to [EngineEvent].
extension EngineEventPatterns on EngineEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( EngineEvent_PtyWrite value)?  ptyWrite,TResult Function( EngineEvent_Title value)?  title,TResult Function( EngineEvent_ResetTitle value)?  resetTitle,TResult Function( EngineEvent_Bell value)?  bell,TResult Function( EngineEvent_ClipboardStore value)?  clipboardStore,TResult Function( EngineEvent_ClipboardLoad value)?  clipboardLoad,required TResult orElse(),}){
final _that = this;
switch (_that) {
case EngineEvent_PtyWrite() when ptyWrite != null:
return ptyWrite(_that);case EngineEvent_Title() when title != null:
return title(_that);case EngineEvent_ResetTitle() when resetTitle != null:
return resetTitle(_that);case EngineEvent_Bell() when bell != null:
return bell(_that);case EngineEvent_ClipboardStore() when clipboardStore != null:
return clipboardStore(_that);case EngineEvent_ClipboardLoad() when clipboardLoad != null:
return clipboardLoad(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( EngineEvent_PtyWrite value)  ptyWrite,required TResult Function( EngineEvent_Title value)  title,required TResult Function( EngineEvent_ResetTitle value)  resetTitle,required TResult Function( EngineEvent_Bell value)  bell,required TResult Function( EngineEvent_ClipboardStore value)  clipboardStore,required TResult Function( EngineEvent_ClipboardLoad value)  clipboardLoad,}){
final _that = this;
switch (_that) {
case EngineEvent_PtyWrite():
return ptyWrite(_that);case EngineEvent_Title():
return title(_that);case EngineEvent_ResetTitle():
return resetTitle(_that);case EngineEvent_Bell():
return bell(_that);case EngineEvent_ClipboardStore():
return clipboardStore(_that);case EngineEvent_ClipboardLoad():
return clipboardLoad(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( EngineEvent_PtyWrite value)?  ptyWrite,TResult? Function( EngineEvent_Title value)?  title,TResult? Function( EngineEvent_ResetTitle value)?  resetTitle,TResult? Function( EngineEvent_Bell value)?  bell,TResult? Function( EngineEvent_ClipboardStore value)?  clipboardStore,TResult? Function( EngineEvent_ClipboardLoad value)?  clipboardLoad,}){
final _that = this;
switch (_that) {
case EngineEvent_PtyWrite() when ptyWrite != null:
return ptyWrite(_that);case EngineEvent_Title() when title != null:
return title(_that);case EngineEvent_ResetTitle() when resetTitle != null:
return resetTitle(_that);case EngineEvent_Bell() when bell != null:
return bell(_that);case EngineEvent_ClipboardStore() when clipboardStore != null:
return clipboardStore(_that);case EngineEvent_ClipboardLoad() when clipboardLoad != null:
return clipboardLoad(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( Uint8List field0)?  ptyWrite,TResult Function( String field0)?  title,TResult Function()?  resetTitle,TResult Function()?  bell,TResult Function( String field0)?  clipboardStore,TResult Function()?  clipboardLoad,required TResult orElse(),}) {final _that = this;
switch (_that) {
case EngineEvent_PtyWrite() when ptyWrite != null:
return ptyWrite(_that.field0);case EngineEvent_Title() when title != null:
return title(_that.field0);case EngineEvent_ResetTitle() when resetTitle != null:
return resetTitle();case EngineEvent_Bell() when bell != null:
return bell();case EngineEvent_ClipboardStore() when clipboardStore != null:
return clipboardStore(_that.field0);case EngineEvent_ClipboardLoad() when clipboardLoad != null:
return clipboardLoad();case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( Uint8List field0)  ptyWrite,required TResult Function( String field0)  title,required TResult Function()  resetTitle,required TResult Function()  bell,required TResult Function( String field0)  clipboardStore,required TResult Function()  clipboardLoad,}) {final _that = this;
switch (_that) {
case EngineEvent_PtyWrite():
return ptyWrite(_that.field0);case EngineEvent_Title():
return title(_that.field0);case EngineEvent_ResetTitle():
return resetTitle();case EngineEvent_Bell():
return bell();case EngineEvent_ClipboardStore():
return clipboardStore(_that.field0);case EngineEvent_ClipboardLoad():
return clipboardLoad();}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( Uint8List field0)?  ptyWrite,TResult? Function( String field0)?  title,TResult? Function()?  resetTitle,TResult? Function()?  bell,TResult? Function( String field0)?  clipboardStore,TResult? Function()?  clipboardLoad,}) {final _that = this;
switch (_that) {
case EngineEvent_PtyWrite() when ptyWrite != null:
return ptyWrite(_that.field0);case EngineEvent_Title() when title != null:
return title(_that.field0);case EngineEvent_ResetTitle() when resetTitle != null:
return resetTitle();case EngineEvent_Bell() when bell != null:
return bell();case EngineEvent_ClipboardStore() when clipboardStore != null:
return clipboardStore(_that.field0);case EngineEvent_ClipboardLoad() when clipboardLoad != null:
return clipboardLoad();case _:
  return null;

}
}

}

/// @nodoc


class EngineEvent_PtyWrite extends EngineEvent {
  const EngineEvent_PtyWrite(this.field0): super._();
  

 final  Uint8List field0;

/// Create a copy of EngineEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EngineEvent_PtyWriteCopyWith<EngineEvent_PtyWrite> get copyWith => _$EngineEvent_PtyWriteCopyWithImpl<EngineEvent_PtyWrite>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EngineEvent_PtyWrite&&const DeepCollectionEquality().equals(other.field0, field0));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(field0));

@override
String toString() {
  return 'EngineEvent.ptyWrite(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EngineEvent_PtyWriteCopyWith<$Res> implements $EngineEventCopyWith<$Res> {
  factory $EngineEvent_PtyWriteCopyWith(EngineEvent_PtyWrite value, $Res Function(EngineEvent_PtyWrite) _then) = _$EngineEvent_PtyWriteCopyWithImpl;
@useResult
$Res call({
 Uint8List field0
});




}
/// @nodoc
class _$EngineEvent_PtyWriteCopyWithImpl<$Res>
    implements $EngineEvent_PtyWriteCopyWith<$Res> {
  _$EngineEvent_PtyWriteCopyWithImpl(this._self, this._then);

  final EngineEvent_PtyWrite _self;
  final $Res Function(EngineEvent_PtyWrite) _then;

/// Create a copy of EngineEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EngineEvent_PtyWrite(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as Uint8List,
  ));
}


}

/// @nodoc


class EngineEvent_Title extends EngineEvent {
  const EngineEvent_Title(this.field0): super._();
  

 final  String field0;

/// Create a copy of EngineEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EngineEvent_TitleCopyWith<EngineEvent_Title> get copyWith => _$EngineEvent_TitleCopyWithImpl<EngineEvent_Title>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EngineEvent_Title&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EngineEvent.title(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EngineEvent_TitleCopyWith<$Res> implements $EngineEventCopyWith<$Res> {
  factory $EngineEvent_TitleCopyWith(EngineEvent_Title value, $Res Function(EngineEvent_Title) _then) = _$EngineEvent_TitleCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$EngineEvent_TitleCopyWithImpl<$Res>
    implements $EngineEvent_TitleCopyWith<$Res> {
  _$EngineEvent_TitleCopyWithImpl(this._self, this._then);

  final EngineEvent_Title _self;
  final $Res Function(EngineEvent_Title) _then;

/// Create a copy of EngineEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EngineEvent_Title(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class EngineEvent_ResetTitle extends EngineEvent {
  const EngineEvent_ResetTitle(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EngineEvent_ResetTitle);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EngineEvent.resetTitle()';
}


}




/// @nodoc


class EngineEvent_Bell extends EngineEvent {
  const EngineEvent_Bell(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EngineEvent_Bell);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EngineEvent.bell()';
}


}




/// @nodoc


class EngineEvent_ClipboardStore extends EngineEvent {
  const EngineEvent_ClipboardStore(this.field0): super._();
  

 final  String field0;

/// Create a copy of EngineEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EngineEvent_ClipboardStoreCopyWith<EngineEvent_ClipboardStore> get copyWith => _$EngineEvent_ClipboardStoreCopyWithImpl<EngineEvent_ClipboardStore>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EngineEvent_ClipboardStore&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'EngineEvent.clipboardStore(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $EngineEvent_ClipboardStoreCopyWith<$Res> implements $EngineEventCopyWith<$Res> {
  factory $EngineEvent_ClipboardStoreCopyWith(EngineEvent_ClipboardStore value, $Res Function(EngineEvent_ClipboardStore) _then) = _$EngineEvent_ClipboardStoreCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$EngineEvent_ClipboardStoreCopyWithImpl<$Res>
    implements $EngineEvent_ClipboardStoreCopyWith<$Res> {
  _$EngineEvent_ClipboardStoreCopyWithImpl(this._self, this._then);

  final EngineEvent_ClipboardStore _self;
  final $Res Function(EngineEvent_ClipboardStore) _then;

/// Create a copy of EngineEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(EngineEvent_ClipboardStore(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class EngineEvent_ClipboardLoad extends EngineEvent {
  const EngineEvent_ClipboardLoad(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EngineEvent_ClipboardLoad);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'EngineEvent.clipboardLoad()';
}


}




// dart format on
