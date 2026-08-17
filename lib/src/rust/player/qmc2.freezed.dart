// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'qmc2.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

/// @nodoc
mixin _$QmcCryptoInner {
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(Qmc2MapCrypto field0) map,
    required TResult Function(Qmc2Rc4Crypto field0) rc4,
    required TResult Function() qmc1,
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(Qmc2MapCrypto field0)? map,
    TResult? Function(Qmc2Rc4Crypto field0)? rc4,
    TResult? Function()? qmc1,
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(Qmc2MapCrypto field0)? map,
    TResult Function(Qmc2Rc4Crypto field0)? rc4,
    TResult Function()? qmc1,
    required TResult orElse(),
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(QmcCryptoInner_Map value) map,
    required TResult Function(QmcCryptoInner_Rc4 value) rc4,
    required TResult Function(QmcCryptoInner_Qmc1 value) qmc1,
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(QmcCryptoInner_Map value)? map,
    TResult? Function(QmcCryptoInner_Rc4 value)? rc4,
    TResult? Function(QmcCryptoInner_Qmc1 value)? qmc1,
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(QmcCryptoInner_Map value)? map,
    TResult Function(QmcCryptoInner_Rc4 value)? rc4,
    TResult Function(QmcCryptoInner_Qmc1 value)? qmc1,
    required TResult orElse(),
  }) => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $QmcCryptoInnerCopyWith<$Res> {
  factory $QmcCryptoInnerCopyWith(
    QmcCryptoInner value,
    $Res Function(QmcCryptoInner) then,
  ) = _$QmcCryptoInnerCopyWithImpl<$Res, QmcCryptoInner>;
}

/// @nodoc
class _$QmcCryptoInnerCopyWithImpl<$Res, $Val extends QmcCryptoInner>
    implements $QmcCryptoInnerCopyWith<$Res> {
  _$QmcCryptoInnerCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of QmcCryptoInner
  /// with the given fields replaced by the non-null parameter values.
}

/// @nodoc
abstract class _$$QmcCryptoInner_MapImplCopyWith<$Res> {
  factory _$$QmcCryptoInner_MapImplCopyWith(
    _$QmcCryptoInner_MapImpl value,
    $Res Function(_$QmcCryptoInner_MapImpl) then,
  ) = __$$QmcCryptoInner_MapImplCopyWithImpl<$Res>;
  @useResult
  $Res call({Qmc2MapCrypto field0});
}

/// @nodoc
class __$$QmcCryptoInner_MapImplCopyWithImpl<$Res>
    extends _$QmcCryptoInnerCopyWithImpl<$Res, _$QmcCryptoInner_MapImpl>
    implements _$$QmcCryptoInner_MapImplCopyWith<$Res> {
  __$$QmcCryptoInner_MapImplCopyWithImpl(
    _$QmcCryptoInner_MapImpl _value,
    $Res Function(_$QmcCryptoInner_MapImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of QmcCryptoInner
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? field0 = null}) {
    return _then(
      _$QmcCryptoInner_MapImpl(
        null == field0
            ? _value.field0
            : field0 // ignore: cast_nullable_to_non_nullable
                  as Qmc2MapCrypto,
      ),
    );
  }
}

/// @nodoc

class _$QmcCryptoInner_MapImpl extends QmcCryptoInner_Map {
  const _$QmcCryptoInner_MapImpl(this.field0) : super._();

  @override
  final Qmc2MapCrypto field0;

  @override
  String toString() {
    return 'QmcCryptoInner.map(field0: $field0)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$QmcCryptoInner_MapImpl &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  /// Create a copy of QmcCryptoInner
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$QmcCryptoInner_MapImplCopyWith<_$QmcCryptoInner_MapImpl> get copyWith =>
      __$$QmcCryptoInner_MapImplCopyWithImpl<_$QmcCryptoInner_MapImpl>(
        this,
        _$identity,
      );

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(Qmc2MapCrypto field0) map,
    required TResult Function(Qmc2Rc4Crypto field0) rc4,
    required TResult Function() qmc1,
  }) {
    return map(field0);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(Qmc2MapCrypto field0)? map,
    TResult? Function(Qmc2Rc4Crypto field0)? rc4,
    TResult? Function()? qmc1,
  }) {
    return map?.call(field0);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(Qmc2MapCrypto field0)? map,
    TResult Function(Qmc2Rc4Crypto field0)? rc4,
    TResult Function()? qmc1,
    required TResult orElse(),
  }) {
    if (map != null) {
      return map(field0);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(QmcCryptoInner_Map value) map,
    required TResult Function(QmcCryptoInner_Rc4 value) rc4,
    required TResult Function(QmcCryptoInner_Qmc1 value) qmc1,
  }) {
    return map(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(QmcCryptoInner_Map value)? map,
    TResult? Function(QmcCryptoInner_Rc4 value)? rc4,
    TResult? Function(QmcCryptoInner_Qmc1 value)? qmc1,
  }) {
    return map?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(QmcCryptoInner_Map value)? map,
    TResult Function(QmcCryptoInner_Rc4 value)? rc4,
    TResult Function(QmcCryptoInner_Qmc1 value)? qmc1,
    required TResult orElse(),
  }) {
    if (map != null) {
      return map(this);
    }
    return orElse();
  }
}

abstract class QmcCryptoInner_Map extends QmcCryptoInner {
  const factory QmcCryptoInner_Map(final Qmc2MapCrypto field0) =
      _$QmcCryptoInner_MapImpl;
  const QmcCryptoInner_Map._() : super._();

  Qmc2MapCrypto get field0;

  /// Create a copy of QmcCryptoInner
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$QmcCryptoInner_MapImplCopyWith<_$QmcCryptoInner_MapImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$QmcCryptoInner_Rc4ImplCopyWith<$Res> {
  factory _$$QmcCryptoInner_Rc4ImplCopyWith(
    _$QmcCryptoInner_Rc4Impl value,
    $Res Function(_$QmcCryptoInner_Rc4Impl) then,
  ) = __$$QmcCryptoInner_Rc4ImplCopyWithImpl<$Res>;
  @useResult
  $Res call({Qmc2Rc4Crypto field0});
}

/// @nodoc
class __$$QmcCryptoInner_Rc4ImplCopyWithImpl<$Res>
    extends _$QmcCryptoInnerCopyWithImpl<$Res, _$QmcCryptoInner_Rc4Impl>
    implements _$$QmcCryptoInner_Rc4ImplCopyWith<$Res> {
  __$$QmcCryptoInner_Rc4ImplCopyWithImpl(
    _$QmcCryptoInner_Rc4Impl _value,
    $Res Function(_$QmcCryptoInner_Rc4Impl) _then,
  ) : super(_value, _then);

  /// Create a copy of QmcCryptoInner
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? field0 = null}) {
    return _then(
      _$QmcCryptoInner_Rc4Impl(
        null == field0
            ? _value.field0
            : field0 // ignore: cast_nullable_to_non_nullable
                  as Qmc2Rc4Crypto,
      ),
    );
  }
}

/// @nodoc

class _$QmcCryptoInner_Rc4Impl extends QmcCryptoInner_Rc4 {
  const _$QmcCryptoInner_Rc4Impl(this.field0) : super._();

  @override
  final Qmc2Rc4Crypto field0;

  @override
  String toString() {
    return 'QmcCryptoInner.rc4(field0: $field0)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$QmcCryptoInner_Rc4Impl &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  /// Create a copy of QmcCryptoInner
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$QmcCryptoInner_Rc4ImplCopyWith<_$QmcCryptoInner_Rc4Impl> get copyWith =>
      __$$QmcCryptoInner_Rc4ImplCopyWithImpl<_$QmcCryptoInner_Rc4Impl>(
        this,
        _$identity,
      );

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(Qmc2MapCrypto field0) map,
    required TResult Function(Qmc2Rc4Crypto field0) rc4,
    required TResult Function() qmc1,
  }) {
    return rc4(field0);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(Qmc2MapCrypto field0)? map,
    TResult? Function(Qmc2Rc4Crypto field0)? rc4,
    TResult? Function()? qmc1,
  }) {
    return rc4?.call(field0);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(Qmc2MapCrypto field0)? map,
    TResult Function(Qmc2Rc4Crypto field0)? rc4,
    TResult Function()? qmc1,
    required TResult orElse(),
  }) {
    if (rc4 != null) {
      return rc4(field0);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(QmcCryptoInner_Map value) map,
    required TResult Function(QmcCryptoInner_Rc4 value) rc4,
    required TResult Function(QmcCryptoInner_Qmc1 value) qmc1,
  }) {
    return rc4(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(QmcCryptoInner_Map value)? map,
    TResult? Function(QmcCryptoInner_Rc4 value)? rc4,
    TResult? Function(QmcCryptoInner_Qmc1 value)? qmc1,
  }) {
    return rc4?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(QmcCryptoInner_Map value)? map,
    TResult Function(QmcCryptoInner_Rc4 value)? rc4,
    TResult Function(QmcCryptoInner_Qmc1 value)? qmc1,
    required TResult orElse(),
  }) {
    if (rc4 != null) {
      return rc4(this);
    }
    return orElse();
  }
}

abstract class QmcCryptoInner_Rc4 extends QmcCryptoInner {
  const factory QmcCryptoInner_Rc4(final Qmc2Rc4Crypto field0) =
      _$QmcCryptoInner_Rc4Impl;
  const QmcCryptoInner_Rc4._() : super._();

  Qmc2Rc4Crypto get field0;

  /// Create a copy of QmcCryptoInner
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$QmcCryptoInner_Rc4ImplCopyWith<_$QmcCryptoInner_Rc4Impl> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$QmcCryptoInner_Qmc1ImplCopyWith<$Res> {
  factory _$$QmcCryptoInner_Qmc1ImplCopyWith(
    _$QmcCryptoInner_Qmc1Impl value,
    $Res Function(_$QmcCryptoInner_Qmc1Impl) then,
  ) = __$$QmcCryptoInner_Qmc1ImplCopyWithImpl<$Res>;
}

/// @nodoc
class __$$QmcCryptoInner_Qmc1ImplCopyWithImpl<$Res>
    extends _$QmcCryptoInnerCopyWithImpl<$Res, _$QmcCryptoInner_Qmc1Impl>
    implements _$$QmcCryptoInner_Qmc1ImplCopyWith<$Res> {
  __$$QmcCryptoInner_Qmc1ImplCopyWithImpl(
    _$QmcCryptoInner_Qmc1Impl _value,
    $Res Function(_$QmcCryptoInner_Qmc1Impl) _then,
  ) : super(_value, _then);

  /// Create a copy of QmcCryptoInner
  /// with the given fields replaced by the non-null parameter values.
}

/// @nodoc

class _$QmcCryptoInner_Qmc1Impl extends QmcCryptoInner_Qmc1 {
  const _$QmcCryptoInner_Qmc1Impl() : super._();

  @override
  String toString() {
    return 'QmcCryptoInner.qmc1()';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$QmcCryptoInner_Qmc1Impl);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(Qmc2MapCrypto field0) map,
    required TResult Function(Qmc2Rc4Crypto field0) rc4,
    required TResult Function() qmc1,
  }) {
    return qmc1();
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(Qmc2MapCrypto field0)? map,
    TResult? Function(Qmc2Rc4Crypto field0)? rc4,
    TResult? Function()? qmc1,
  }) {
    return qmc1?.call();
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(Qmc2MapCrypto field0)? map,
    TResult Function(Qmc2Rc4Crypto field0)? rc4,
    TResult Function()? qmc1,
    required TResult orElse(),
  }) {
    if (qmc1 != null) {
      return qmc1();
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(QmcCryptoInner_Map value) map,
    required TResult Function(QmcCryptoInner_Rc4 value) rc4,
    required TResult Function(QmcCryptoInner_Qmc1 value) qmc1,
  }) {
    return qmc1(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(QmcCryptoInner_Map value)? map,
    TResult? Function(QmcCryptoInner_Rc4 value)? rc4,
    TResult? Function(QmcCryptoInner_Qmc1 value)? qmc1,
  }) {
    return qmc1?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(QmcCryptoInner_Map value)? map,
    TResult Function(QmcCryptoInner_Rc4 value)? rc4,
    TResult Function(QmcCryptoInner_Qmc1 value)? qmc1,
    required TResult orElse(),
  }) {
    if (qmc1 != null) {
      return qmc1(this);
    }
    return orElse();
  }
}

abstract class QmcCryptoInner_Qmc1 extends QmcCryptoInner {
  const factory QmcCryptoInner_Qmc1() = _$QmcCryptoInner_Qmc1Impl;
  const QmcCryptoInner_Qmc1._() : super._();
}
