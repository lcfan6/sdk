// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart2js.kernel.element_map;

import 'package:front_end/src/api_unstable/dart2js.dart' show Link, LinkBuilder;
import 'package:js_runtime/shared/embedded_names.dart';
import 'package:kernel/ast.dart' as ir;
import 'package:kernel/class_hierarchy.dart' as ir;
import 'package:kernel/core_types.dart' as ir;
import 'package:kernel/type_algebra.dart' as ir;
import 'package:kernel/type_environment.dart' as ir;

import '../common.dart';
import '../common/names.dart';
import '../common/resolution.dart';
import '../common_elements.dart';
import '../compile_time_constants.dart';
import '../constants/constant_system.dart';
import '../constants/constructors.dart';
import '../constants/evaluation.dart';
import '../constants/expressions.dart';
import '../constants/values.dart';
import '../elements/entities.dart';
import '../elements/indexed.dart';
import '../elements/names.dart';
import '../elements/types.dart';
import '../environment.dart';
import '../frontend_strategy.dart';
import '../ir/debug.dart';
import '../ir/element_map.dart';
import '../ir/scope.dart';
import '../ir/types.dart';
import '../ir/visitors.dart';
import '../ir/util.dart';
import '../js/js.dart' as js;
import '../js_backend/backend.dart' show JavaScriptBackend;
import '../js_backend/constant_system_javascript.dart';
import '../js_backend/namer.dart';
import '../js_backend/native_data.dart';
import '../js_backend/no_such_method_registry.dart';
import '../js_model/locals.dart';
import '../native/native.dart' as native;
import '../native/resolver.dart';
import '../options.dart';
import '../ordered_typeset.dart';
import '../universe/call_structure.dart';
import '../universe/class_hierarchy.dart';
import '../universe/selector.dart';

import 'element_map.dart';
import 'env.dart';
import 'kelements.dart';
import 'kernel_impact.dart';

part 'native_basic_data.dart';
part 'no_such_method_resolver.dart';

/// Implementation of [KernelToElementMap] that only supports world
/// impact computation.
class KernelToElementMapImpl implements KernelToElementMap, IrToElementMap {
  final CompilerOptions options;
  final DiagnosticReporter reporter;
  CommonElementsImpl _commonElements;
  KernelElementEnvironment _elementEnvironment;
  DartTypeConverter _typeConverter;
  KernelConstantEnvironment _constantEnvironment;
  KernelDartTypes _types;
  ir.TypeEnvironment _typeEnvironment;

  /// Library environment. Used for fast lookup.
  KProgramEnv env = new KProgramEnv();

  final EntityDataEnvMap<IndexedLibrary, KLibraryData, KLibraryEnv> libraries =
      new EntityDataEnvMap<IndexedLibrary, KLibraryData, KLibraryEnv>();
  final EntityDataEnvMap<IndexedClass, KClassData, KClassEnv> classes =
      new EntityDataEnvMap<IndexedClass, KClassData, KClassEnv>();
  final EntityDataMap<IndexedMember, KMemberData> members =
      new EntityDataMap<IndexedMember, KMemberData>();
  final EntityDataMap<IndexedTypeVariable, KTypeVariableData> typeVariables =
      new EntityDataMap<IndexedTypeVariable, KTypeVariableData>();
  final EntityDataMap<IndexedTypedef, KTypedefData> typedefs =
      new EntityDataMap<IndexedTypedef, KTypedefData>();

  /// Set to `true` before creating the J-World from the K-World to assert that
  /// no entities are created late.
  bool envIsClosed = false;

  final Map<ir.Library, IndexedLibrary> libraryMap = {};
  final Map<ir.Class, IndexedClass> classMap = {};
  final Map<ir.Typedef, IndexedTypedef> typedefMap = {};

  /// Map from [ir.TypeParameter] nodes to the corresponding
  /// [TypeVariableEntity].
  ///
  /// Normally the type variables are [IndexedTypeVariable]s, but for type
  /// parameters on local function (in the frontend) these are _not_ since
  /// their type declaration is neither a class nor a member. In the backend,
  /// these type parameters belong to the call-method and are therefore indexed.
  final Map<ir.TypeParameter, TypeVariableEntity> typeVariableMap = {};
  final Map<ir.Member, IndexedConstructor> constructorMap = {};
  final Map<ir.Procedure, IndexedFunction> methodMap = {};
  final Map<ir.Field, IndexedField> fieldMap = {};
  final Map<ir.TreeNode, Local> localFunctionMap = {};

  native.BehaviorBuilder _nativeBehaviorBuilder;
  FrontendStrategy _frontendStrategy;

  Map<KMember, Map<ir.TreeNode, ir.DartType>> staticTypeCacheForTesting;

  KernelToElementMapImpl(this.reporter, Environment environment,
      this._frontendStrategy, this.options) {
    _elementEnvironment = new KernelElementEnvironment(this);
    _commonElements = new CommonElementsImpl(_elementEnvironment);
    _constantEnvironment = new KernelConstantEnvironment(this, environment);
    _typeConverter = new DartTypeConverter(this);
    _types = new KernelDartTypes(this);
  }

  DartTypes get types => _types;

  KernelElementEnvironment get elementEnvironment => _elementEnvironment;

  @override
  CommonElementsImpl get commonElements => _commonElements;

  FunctionEntity get _mainFunction {
    return env.mainMethod != null ? getMethodInternal(env.mainMethod) : null;
  }

  LibraryEntity get _mainLibrary {
    return env.mainMethod != null
        ? getLibraryInternal(env.mainMethod.enclosingLibrary)
        : null;
  }

  SourceSpan getSourceSpan(Spannable spannable, Entity currentElement) {
    SourceSpan fromSpannable(Spannable spannable) {
      if (spannable is IndexedLibrary &&
          spannable.libraryIndex < libraries.length) {
        KLibraryEnv env = libraries.getEnv(spannable);
        return computeSourceSpanFromTreeNode(env.library);
      } else if (spannable is IndexedClass &&
          spannable.classIndex < classes.length) {
        KClassData data = classes.getData(spannable);
        assert(data != null, "No data for $spannable in $this");
        return computeSourceSpanFromTreeNode(data.node);
      } else if (spannable is IndexedMember &&
          spannable.memberIndex < members.length) {
        KMemberData data = members.getData(spannable);
        assert(data != null, "No data for $spannable in $this");
        return computeSourceSpanFromTreeNode(data.node);
      } else if (spannable is KLocalFunction) {
        return getSourceSpan(spannable.memberContext, currentElement);
      } else if (spannable is JLocal) {
        return getSourceSpan(spannable.memberContext, currentElement);
      }
      return null;
    }

    SourceSpan sourceSpan = fromSpannable(spannable);
    sourceSpan ??= fromSpannable(currentElement);
    return sourceSpan;
  }

  LibraryEntity lookupLibrary(Uri uri) {
    KLibraryEnv libraryEnv = env.lookupLibrary(uri);
    if (libraryEnv == null) return null;
    return getLibraryInternal(libraryEnv.library, libraryEnv);
  }

  String _getLibraryName(IndexedLibrary library) {
    assert(checkFamily(library));
    KLibraryEnv libraryEnv = libraries.getEnv(library);
    return libraryEnv.library.name ?? '';
  }

  MemberEntity lookupLibraryMember(IndexedLibrary library, String name,
      {bool setter: false}) {
    assert(checkFamily(library));
    KLibraryEnv libraryEnv = libraries.getEnv(library);
    ir.Member member = libraryEnv.lookupMember(name, setter: setter);
    return member != null ? getMember(member) : null;
  }

  void _forEachLibraryMember(
      IndexedLibrary library, void f(MemberEntity member)) {
    assert(checkFamily(library));
    KLibraryEnv libraryEnv = libraries.getEnv(library);
    libraryEnv.forEachMember((ir.Member node) {
      f(getMember(node));
    });
  }

  ClassEntity lookupClass(IndexedLibrary library, String name) {
    assert(checkFamily(library));
    KLibraryEnv libraryEnv = libraries.getEnv(library);
    KClassEnv classEnv = libraryEnv.lookupClass(name);
    if (classEnv != null) {
      return getClassInternal(classEnv.cls, classEnv);
    }
    return null;
  }

  void _forEachClass(IndexedLibrary library, void f(ClassEntity cls)) {
    assert(checkFamily(library));
    KLibraryEnv libraryEnv = libraries.getEnv(library);
    libraryEnv.forEachClass((KClassEnv classEnv) {
      if (!classEnv.isUnnamedMixinApplication) {
        f(getClassInternal(classEnv.cls, classEnv));
      }
    });
  }

  void ensureClassMembers(ir.Class node) {
    classes.getEnv(getClassInternal(node)).ensureMembers(this);
  }

  MemberEntity lookupClassMember(IndexedClass cls, String name,
      {bool setter: false}) {
    assert(checkFamily(cls));
    KClassEnv classEnv = classes.getEnv(cls);
    return classEnv.lookupMember(this, name, setter: setter);
  }

  ConstructorEntity lookupConstructor(IndexedClass cls, String name) {
    assert(checkFamily(cls));
    KClassEnv classEnv = classes.getEnv(cls);
    return classEnv.lookupConstructor(this, name);
  }

  @override
  InterfaceType createInterfaceType(
      ir.Class cls, List<ir.DartType> typeArguments) {
    return new InterfaceType(getClass(cls), getDartTypes(typeArguments));
  }

  LibraryEntity getLibrary(ir.Library node) => getLibraryInternal(node);

  @override
  ClassEntity getClass(ir.Class node) => getClassInternal(node);

  InterfaceType getSuperType(IndexedClass cls) {
    assert(checkFamily(cls));
    KClassData data = classes.getData(cls);
    _ensureSupertypes(cls, data);
    return data.supertype;
  }

  void _ensureThisAndRawType(ClassEntity cls, KClassData data) {
    assert(checkFamily(cls));
    if (data is KClassDataImpl && data.thisType == null) {
      ir.Class node = data.node;
      if (node.typeParameters.isEmpty) {
        data.thisType =
            data.rawType = new InterfaceType(cls, const <DartType>[]);
      } else {
        data.thisType = new InterfaceType(
            cls,
            new List<DartType>.generate(node.typeParameters.length,
                (int index) {
              return new TypeVariableType(
                  getTypeVariableInternal(node.typeParameters[index]));
            }));
        data.rawType = new InterfaceType(
            cls,
            new List<DartType>.filled(
                node.typeParameters.length, const DynamicType()));
      }
    }
  }

  TypeVariableEntity getTypeVariable(ir.TypeParameter node) =>
      getTypeVariableInternal(node);

  void _ensureSupertypes(ClassEntity cls, KClassData data) {
    assert(checkFamily(cls));
    if (data is KClassDataImpl && data.orderedTypeSet == null) {
      _ensureThisAndRawType(cls, data);

      ir.Class node = data.node;

      if (node.supertype == null) {
        data.orderedTypeSet = new OrderedTypeSet.singleton(data.thisType);
        data.isMixinApplication = false;
        data.interfaces = const <InterfaceType>[];
      } else {
        InterfaceType processSupertype(ir.Supertype node) {
          InterfaceType supertype = _typeConverter.visitSupertype(node);
          IndexedClass superclass = supertype.element;
          KClassData superdata = classes.getData(superclass);
          _ensureSupertypes(superclass, superdata);
          return supertype;
        }

        InterfaceType supertype;
        LinkBuilder<InterfaceType> linkBuilder =
            new LinkBuilder<InterfaceType>();
        if (node.isMixinDeclaration) {
          // A mixin declaration
          //
          //   mixin M on A, B, C {}
          //
          // is encoded by CFE as
          //
          //   abstract class M extends A implements B, C {}
          //   abstract class M extends A&B&C {}
          //
          // but we encode it as
          //
          //   abstract class M extends Object implements A, B, C {}
          //
          // so we need get the superclasses from the on-clause, A, B, and C,
          // through [superclassConstraints].
          for (ir.Supertype constraint in node.superclassConstraints()) {
            linkBuilder.addLast(processSupertype(constraint));
          }
          // Set superclass to `Object`.
          supertype = _commonElements.objectType;
        } else {
          supertype = processSupertype(node.supertype);
        }
        if (supertype == _commonElements.objectType) {
          ClassEntity defaultSuperclass =
              _commonElements.getDefaultSuperclass(cls, nativeBasicData);
          data.supertype = _elementEnvironment.getRawType(defaultSuperclass);
        } else {
          data.supertype = supertype;
        }
        if (node.mixedInType != null) {
          data.isMixinApplication = true;
          linkBuilder
              .addLast(data.mixedInType = processSupertype(node.mixedInType));
        } else {
          data.isMixinApplication = false;
        }
        node.implementedTypes.forEach((ir.Supertype supertype) {
          linkBuilder.addLast(processSupertype(supertype));
        });
        Link<InterfaceType> interfaces =
            linkBuilder.toLink(const Link<InterfaceType>());
        OrderedTypeSetBuilder setBuilder =
            new KernelOrderedTypeSetBuilder(this, cls);
        data.orderedTypeSet = setBuilder.createOrderedTypeSet(
            data.supertype, interfaces.reverse(const Link<InterfaceType>()));
        data.interfaces = new List<InterfaceType>.from(interfaces.toList());
      }
    }
  }

  @override
  TypedefType getTypedefType(ir.Typedef node) {
    IndexedTypedef typedef = getTypedefInternal(node);
    return typedefs.getData(typedef).rawType;
  }

  @override
  MemberEntity getMember(ir.Member node) {
    if (node is ir.Field) {
      return getFieldInternal(node);
    } else if (node is ir.Constructor) {
      return getConstructorInternal(node);
    } else if (node is ir.Procedure) {
      if (node.kind == ir.ProcedureKind.Factory) {
        return getConstructorInternal(node);
      } else {
        return getMethodInternal(node);
      }
    }
    throw new UnsupportedError("Unexpected member: $node");
  }

  MemberEntity getSuperMember(MemberEntity context, ir.Name name,
      {bool setter: false}) {
    // We can no longer trust the interface target of the super access since it
    // might be a member that we have cloned.
    ClassEntity cls = context.enclosingClass;
    assert(
        cls != null,
        failedAt(context,
            "No enclosing class for super member access in $context."));
    IndexedClass superclass = getSuperType(cls)?.element;
    while (superclass != null) {
      KClassEnv env = classes.getEnv(superclass);
      MemberEntity superMember =
          env.lookupMember(this, name.name, setter: setter);
      if (superMember != null) {
        if (!superMember.isInstanceMember) return null;
        if (!superMember.isAbstract) {
          return superMember;
        }
      }
      superclass = getSuperType(superclass)?.element;
    }
    return null;
  }

  @override
  ConstructorEntity getConstructor(ir.Member node) =>
      getConstructorInternal(node);

  ConstructorEntity getSuperConstructor(
      ir.Constructor sourceNode, ir.Member targetNode) {
    ConstructorEntity source = getConstructor(sourceNode);
    ClassEntity sourceClass = source.enclosingClass;
    ConstructorEntity target = getConstructor(targetNode);
    ClassEntity targetClass = target.enclosingClass;
    IndexedClass superClass = getSuperType(sourceClass)?.element;
    if (superClass == targetClass) {
      return target;
    }
    KClassEnv env = classes.getEnv(superClass);
    ConstructorEntity constructor = env.lookupConstructor(this, target.name);
    if (constructor != null) {
      return constructor;
    }
    throw failedAt(source, "Super constructor for $source not found.");
  }

  @override
  FunctionEntity getMethod(ir.Procedure node) => getMethodInternal(node);

  @override
  FieldEntity getField(ir.Field node) => getFieldInternal(node);

  @override
  DartType getDartType(ir.DartType type) => _typeConverter.convert(type);

  TypeVariableType getTypeVariableType(ir.TypeParameterType type) =>
      getDartType(type);

  List<DartType> getDartTypes(List<ir.DartType> types) {
    List<DartType> list = <DartType>[];
    types.forEach((ir.DartType type) {
      list.add(getDartType(type));
    });
    return list;
  }

  InterfaceType getInterfaceType(ir.InterfaceType type) =>
      _typeConverter.convert(type);

  @override
  FunctionType getFunctionType(ir.FunctionNode node) {
    DartType returnType;
    if (node.parent is ir.Constructor) {
      // The return type on generative constructors is `void`, but we need
      // `dynamic` type to match the element model.
      returnType = const DynamicType();
    } else {
      returnType = getDartType(node.returnType);
    }
    List<DartType> parameterTypes = <DartType>[];
    List<DartType> optionalParameterTypes = <DartType>[];

    DartType getParameterType(ir.VariableDeclaration variable) {
      if (variable.isCovariant || variable.isGenericCovariantImpl) {
        // A covariant parameter has type `Object` in the method signature.
        return commonElements.objectType;
      }
      return getDartType(variable.type);
    }

    for (ir.VariableDeclaration variable in node.positionalParameters) {
      if (parameterTypes.length == node.requiredParameterCount) {
        optionalParameterTypes.add(getParameterType(variable));
      } else {
        parameterTypes.add(getParameterType(variable));
      }
    }
    List<String> namedParameters = <String>[];
    List<DartType> namedParameterTypes = <DartType>[];
    List<ir.VariableDeclaration> sortedNamedParameters =
        node.namedParameters.toList()..sort((a, b) => a.name.compareTo(b.name));
    for (ir.VariableDeclaration variable in sortedNamedParameters) {
      namedParameters.add(variable.name);
      namedParameterTypes.add(getParameterType(variable));
    }
    List<FunctionTypeVariable> typeVariables;
    if (node.typeParameters.isNotEmpty) {
      List<DartType> typeParameters = <DartType>[];
      for (ir.TypeParameter typeParameter in node.typeParameters) {
        typeParameters
            .add(getDartType(new ir.TypeParameterType(typeParameter)));
      }
      typeVariables = new List<FunctionTypeVariable>.generate(
          node.typeParameters.length,
          (int index) => new FunctionTypeVariable(index));

      DartType subst(DartType type) {
        return type.subst(typeVariables, typeParameters);
      }

      returnType = subst(returnType);
      parameterTypes = parameterTypes.map(subst).toList();
      optionalParameterTypes = optionalParameterTypes.map(subst).toList();
      namedParameterTypes = namedParameterTypes.map(subst).toList();
      for (int index = 0; index < typeVariables.length; index++) {
        typeVariables[index].bound =
            subst(getDartType(node.typeParameters[index].bound));
      }
    } else {
      typeVariables = const <FunctionTypeVariable>[];
    }

    return new FunctionType(returnType, parameterTypes, optionalParameterTypes,
        namedParameters, namedParameterTypes, typeVariables);
  }

  ConstantValue computeConstantValue(
      Spannable spannable, ConstantExpression constant,
      {bool requireConstant: true, bool checkCasts: true}) {
    return _constantEnvironment._getConstantValue(spannable, constant,
        constantRequired: requireConstant, checkCasts: checkCasts);
  }

  DartType substByContext(DartType type, InterfaceType context) {
    return type.subst(
        context.typeArguments, getThisType(context.element).typeArguments);
  }

  /// Returns the type of the `call` method on 'type'.
  ///
  /// If [type] doesn't have a `call` member `null` is returned. If [type] has
  /// an invalid `call` member (non-method or a synthesized method with both
  /// optional and named parameters) a [DynamicType] is returned.
  DartType getCallType(InterfaceType type) {
    IndexedClass cls = type.element;
    assert(checkFamily(cls));
    KClassData data = classes.getData(cls);
    if (data.callType != null) {
      return substByContext(data.callType, type);
    }
    return null;
  }

  InterfaceType getThisType(IndexedClass cls) {
    assert(checkFamily(cls));
    KClassData data = classes.getData(cls);
    _ensureThisAndRawType(cls, data);
    return data.thisType;
  }

  InterfaceType _getRawType(IndexedClass cls) {
    assert(checkFamily(cls));
    KClassData data = classes.getData(cls);
    _ensureThisAndRawType(cls, data);
    return data.rawType;
  }

  DartType _getFieldType(IndexedField field) {
    assert(checkFamily(field));
    KFieldData data = members.getData(field);
    return data.getFieldType(this);
  }

  FunctionType _getFunctionType(IndexedFunction function) {
    assert(checkFamily(function));
    KFunctionData data = members.getData(function);
    return data.getFunctionType(this);
  }

  List<TypeVariableType> _getFunctionTypeVariables(IndexedFunction function) {
    assert(checkFamily(function));
    KFunctionData data = members.getData(function);
    return data.getFunctionTypeVariables(this);
  }

  DartType getTypeVariableBound(IndexedTypeVariable typeVariable) {
    assert(checkFamily(typeVariable));
    KTypeVariableData data = typeVariables.getData(typeVariable);
    return data.getBound(this);
  }

  ClassEntity getAppliedMixin(IndexedClass cls) {
    assert(checkFamily(cls));
    KClassData data = classes.getData(cls);
    _ensureSupertypes(cls, data);
    return data.mixedInType?.element;
  }

  bool _isMixinApplication(IndexedClass cls) {
    assert(checkFamily(cls));
    KClassData data = classes.getData(cls);
    _ensureSupertypes(cls, data);
    return data.isMixinApplication;
  }

  bool _isUnnamedMixinApplication(IndexedClass cls) {
    assert(checkFamily(cls));
    KClassEnv env = classes.getEnv(cls);
    return env.isUnnamedMixinApplication;
  }

  void _forEachSupertype(IndexedClass cls, void f(InterfaceType supertype)) {
    assert(checkFamily(cls));
    KClassData data = classes.getData(cls);
    _ensureSupertypes(cls, data);
    data.orderedTypeSet.supertypes.forEach(f);
  }

  void _forEachMixin(IndexedClass cls, void f(ClassEntity mixin)) {
    assert(checkFamily(cls));
    while (cls != null) {
      KClassData data = classes.getData(cls);
      _ensureSupertypes(cls, data);
      if (data.mixedInType != null) {
        f(data.mixedInType.element);
      }
      cls = data.supertype?.element;
    }
  }

  void _forEachConstructor(IndexedClass cls, void f(ConstructorEntity member)) {
    assert(checkFamily(cls));
    KClassEnv env = classes.getEnv(cls);
    env.forEachConstructor(this, f);
  }

  void _forEachLocalClassMember(IndexedClass cls, void f(MemberEntity member)) {
    assert(checkFamily(cls));
    KClassEnv env = classes.getEnv(cls);
    env.forEachMember(this, (MemberEntity member) {
      f(member);
    });
  }

  void forEachInjectedClassMember(
      IndexedClass cls, void f(MemberEntity member)) {
    assert(checkFamily(cls));
    throw new UnsupportedError(
        'KernelToElementMapBase._forEachInjectedClassMember');
  }

  void _forEachClassMember(
      IndexedClass cls, void f(ClassEntity cls, MemberEntity member)) {
    assert(checkFamily(cls));
    KClassEnv env = classes.getEnv(cls);
    env.forEachMember(this, (MemberEntity member) {
      f(cls, member);
    });
    KClassData data = classes.getData(cls);
    _ensureSupertypes(cls, data);
    if (data.supertype != null) {
      _forEachClassMember(data.supertype.element, f);
    }
  }

  ConstantConstructor _getConstructorConstant(IndexedConstructor constructor) {
    assert(checkFamily(constructor));
    KConstructorData data = members.getData(constructor);
    return data.getConstructorConstant(this, constructor);
  }

  ConstantExpression _getFieldConstantExpression(IndexedField field) {
    assert(checkFamily(field));
    KFieldData data = members.getData(field);
    return data.getFieldConstantExpression(this);
  }

  InterfaceType asInstanceOf(InterfaceType type, ClassEntity cls) {
    assert(checkFamily(cls));
    OrderedTypeSet orderedTypeSet = getOrderedTypeSet(type.element);
    InterfaceType supertype =
        orderedTypeSet.asInstanceOf(cls, getHierarchyDepth(cls));
    if (supertype != null) {
      supertype = substByContext(supertype, type);
    }
    return supertype;
  }

  OrderedTypeSet getOrderedTypeSet(IndexedClass cls) {
    assert(checkFamily(cls));
    KClassData data = classes.getData(cls);
    _ensureSupertypes(cls, data);
    return data.orderedTypeSet;
  }

  int getHierarchyDepth(IndexedClass cls) {
    assert(checkFamily(cls));
    KClassData data = classes.getData(cls);
    _ensureSupertypes(cls, data);
    return data.orderedTypeSet.maxDepth;
  }

  Iterable<InterfaceType> getInterfaces(IndexedClass cls) {
    assert(checkFamily(cls));
    KClassData data = classes.getData(cls);
    _ensureSupertypes(cls, data);
    return data.interfaces;
  }

  ir.Member getMemberNode(covariant IndexedMember member) {
    assert(checkFamily(member));
    return members.getData(member).node;
  }

  ir.Class getClassNode(covariant IndexedClass cls) {
    assert(checkFamily(cls));
    return classes.getData(cls).node;
  }

  ir.Typedef _getTypedefNode(covariant IndexedTypedef typedef) {
    return typedefs.getData(typedef).node;
  }

  ImportEntity getImport(ir.LibraryDependency node) {
    ir.Library library = node.parent;
    KLibraryData data = libraries.getData(getLibraryInternal(library));
    return data.imports[node];
  }

  ir.TypeEnvironment get typeEnvironment {
    if (_typeEnvironment == null) {
      _typeEnvironment ??= new ir.TypeEnvironment(
          new ir.CoreTypes(env.mainComponent),
          new ir.ClassHierarchy(env.mainComponent));
    }
    return _typeEnvironment;
  }

  DartType getStaticType(ir.Expression node) {
    ir.TreeNode enclosingClass = node;
    while (enclosingClass != null && enclosingClass is! ir.Class) {
      enclosingClass = enclosingClass.parent;
    }
    try {
      typeEnvironment.thisType =
          enclosingClass is ir.Class ? enclosingClass.thisType : null;
      return getDartType(node.getStaticType(typeEnvironment));
    } catch (e) {
      // The static type computation crashes on type errors. Use `dynamic`
      // as static type.
      return commonElements.dynamicType;
    }
  }

  Name getName(ir.Name name) {
    return new Name(
        name.name, name.isPrivate ? getLibrary(name.library) : null);
  }

  CallStructure getCallStructure(ir.Arguments arguments) {
    int argumentCount = arguments.positional.length + arguments.named.length;
    List<String> namedArguments = arguments.named.map((e) => e.name).toList();
    return new CallStructure(
        argumentCount, namedArguments, arguments.types.length);
  }

  ParameterStructure getParameterStructure(ir.FunctionNode node,
      // TODO(johnniwinther): Remove this when type arguments are passed to
      // constructors like calling a generic method.
      {bool includeTypeParameters: true}) {
    // TODO(johnniwinther): Cache the computed function type.
    int requiredParameters = node.requiredParameterCount;
    int positionalParameters = node.positionalParameters.length;
    int typeParameters = node.typeParameters.length;
    List<String> namedParameters =
        node.namedParameters.map((p) => p.name).toList()..sort();
    return new ParameterStructure(requiredParameters, positionalParameters,
        namedParameters, includeTypeParameters ? typeParameters : 0);
  }

  Selector getSelector(ir.Expression node) {
    // TODO(efortuna): This is screaming for a common interface between
    // PropertyGet and SuperPropertyGet (and same for *Get). Talk to kernel
    // folks.
    if (node is ir.PropertyGet) {
      return getGetterSelector(node.name);
    }
    if (node is ir.SuperPropertyGet) {
      return getGetterSelector(node.name);
    }
    if (node is ir.PropertySet) {
      return getSetterSelector(node.name);
    }
    if (node is ir.SuperPropertySet) {
      return getSetterSelector(node.name);
    }
    if (node is ir.InvocationExpression) {
      return getInvocationSelector(node);
    }
    throw failedAt(
        CURRENT_ELEMENT_SPANNABLE,
        "Can only get the selector for a property get or an invocation: "
        "${node}");
  }

  Selector getInvocationSelector(ir.InvocationExpression invocation) {
    Name name = getName(invocation.name);
    SelectorKind kind;
    if (Selector.isOperatorName(name.text)) {
      if (name == Names.INDEX_NAME || name == Names.INDEX_SET_NAME) {
        kind = SelectorKind.INDEX;
      } else {
        kind = SelectorKind.OPERATOR;
      }
    } else {
      kind = SelectorKind.CALL;
    }

    CallStructure callStructure = getCallStructure(invocation.arguments);
    return new Selector(kind, name, callStructure);
  }

  Selector getGetterSelector(ir.Name irName) {
    Name name = new Name(
        irName.name, irName.isPrivate ? getLibrary(irName.library) : null);
    return new Selector.getter(name);
  }

  Selector getSetterSelector(ir.Name irName) {
    Name name = new Name(
        irName.name, irName.isPrivate ? getLibrary(irName.library) : null);
    return new Selector.setter(name);
  }

  /// Looks up [typeName] for use in the spec-string of a `JS` call.
  // TODO(johnniwinther): Use this in [native.NativeBehavior] instead of calling
  // the `ForeignResolver`.
  native.TypeLookup typeLookup({bool resolveAsRaw: true}) {
    return resolveAsRaw
        ? (_cachedTypeLookupRaw ??= _typeLookup(resolveAsRaw: true))
        : (_cachedTypeLookupFull ??= _typeLookup(resolveAsRaw: false));
  }

  native.TypeLookup _cachedTypeLookupRaw;
  native.TypeLookup _cachedTypeLookupFull;

  native.TypeLookup _typeLookup({bool resolveAsRaw: true}) {
    bool cachedMayLookupInMain;
    bool mayLookupInMain() {
      var mainUri = elementEnvironment.mainLibrary.canonicalUri;
      // Tests permit lookup outside of dart: libraries.
      return mainUri.path.contains('tests/compiler/dart2js_native') ||
          mainUri.path.contains('tests/compiler/dart2js_extra');
    }

    DartType lookup(String typeName, {bool required}) {
      DartType findInLibrary(LibraryEntity library) {
        if (library != null) {
          ClassEntity cls = elementEnvironment.lookupClass(library, typeName);
          if (cls != null) {
            // TODO(johnniwinther): Align semantics.
            return resolveAsRaw
                ? elementEnvironment.getRawType(cls)
                : elementEnvironment.getThisType(cls);
          }
        }
        return null;
      }

      DartType findIn(Uri uri) {
        return findInLibrary(elementEnvironment.lookupLibrary(uri));
      }

      // TODO(johnniwinther): Narrow the set of lookups based on the depending
      // library.
      // TODO(johnniwinther): Cache more results to avoid redundant lookups?
      DartType type;
      if (cachedMayLookupInMain ??= mayLookupInMain()) {
        type ??= findInLibrary(elementEnvironment.mainLibrary);
      }
      type ??= findIn(Uris.dart_core);
      type ??= findIn(Uris.dart__js_helper);
      type ??= findIn(Uris.dart__interceptors);
      type ??= findIn(Uris.dart__native_typed_data);
      type ??= findIn(Uris.dart_collection);
      type ??= findIn(Uris.dart_math);
      type ??= findIn(Uris.dart_html);
      type ??= findIn(Uris.dart_html_common);
      type ??= findIn(Uris.dart_svg);
      type ??= findIn(Uris.dart_web_audio);
      type ??= findIn(Uris.dart_web_gl);
      type ??= findIn(Uris.dart_web_sql);
      type ??= findIn(Uris.dart_indexed_db);
      type ??= findIn(Uris.dart_typed_data);
      type ??= findIn(Uris.dart_mirrors);
      if (type == null && required) {
        reporter.reportErrorMessage(CURRENT_ELEMENT_SPANNABLE,
            MessageKind.GENERIC, {'text': "Type '$typeName' not found."});
      }
      return type;
    }

    return lookup;
  }

  String _getStringArgument(ir.StaticInvocation node, int index) {
    return node.arguments.positional[index].accept(new Stringifier());
  }

  /// Computes the [native.NativeBehavior] for a call to the [JS] function.
  // TODO(johnniwinther): Cache this for later use.
  native.NativeBehavior getNativeBehaviorForJsCall(ir.StaticInvocation node) {
    if (node.arguments.positional.length < 2 ||
        node.arguments.named.isNotEmpty) {
      reporter.reportErrorMessage(
          CURRENT_ELEMENT_SPANNABLE, MessageKind.WRONG_ARGUMENT_FOR_JS);
      return new native.NativeBehavior();
    }
    String specString = _getStringArgument(node, 0);
    if (specString == null) {
      reporter.reportErrorMessage(
          CURRENT_ELEMENT_SPANNABLE, MessageKind.WRONG_ARGUMENT_FOR_JS_FIRST);
      return new native.NativeBehavior();
    }

    String codeString = _getStringArgument(node, 1);
    if (codeString == null) {
      reporter.reportErrorMessage(
          CURRENT_ELEMENT_SPANNABLE, MessageKind.WRONG_ARGUMENT_FOR_JS_SECOND);
      return new native.NativeBehavior();
    }

    return native.NativeBehavior.ofJsCall(
        specString,
        codeString,
        typeLookup(resolveAsRaw: true),
        CURRENT_ELEMENT_SPANNABLE,
        reporter,
        commonElements);
  }

  /// Computes the [native.NativeBehavior] for a call to the [JS_BUILTIN]
  /// function.
  // TODO(johnniwinther): Cache this for later use.
  native.NativeBehavior getNativeBehaviorForJsBuiltinCall(
      ir.StaticInvocation node) {
    if (node.arguments.positional.length < 1) {
      reporter.internalError(
          CURRENT_ELEMENT_SPANNABLE, "JS builtin expression has no type.");
      return new native.NativeBehavior();
    }
    if (node.arguments.positional.length < 2) {
      reporter.internalError(
          CURRENT_ELEMENT_SPANNABLE, "JS builtin is missing name.");
      return new native.NativeBehavior();
    }
    String specString = _getStringArgument(node, 0);
    if (specString == null) {
      reporter.internalError(
          CURRENT_ELEMENT_SPANNABLE, "Unexpected first argument.");
      return new native.NativeBehavior();
    }
    return native.NativeBehavior.ofJsBuiltinCall(
        specString,
        typeLookup(resolveAsRaw: true),
        CURRENT_ELEMENT_SPANNABLE,
        reporter,
        commonElements);
  }

  /// Computes the [native.NativeBehavior] for a call to the
  /// [JS_EMBEDDED_GLOBAL] function.
  // TODO(johnniwinther): Cache this for later use.
  native.NativeBehavior getNativeBehaviorForJsEmbeddedGlobalCall(
      ir.StaticInvocation node) {
    if (node.arguments.positional.length < 1) {
      reporter.internalError(CURRENT_ELEMENT_SPANNABLE,
          "JS embedded global expression has no type.");
      return new native.NativeBehavior();
    }
    if (node.arguments.positional.length < 2) {
      reporter.internalError(
          CURRENT_ELEMENT_SPANNABLE, "JS embedded global is missing name.");
      return new native.NativeBehavior();
    }
    if (node.arguments.positional.length > 2 ||
        node.arguments.named.isNotEmpty) {
      reporter.internalError(CURRENT_ELEMENT_SPANNABLE,
          "JS embedded global has more than 2 arguments.");
      return new native.NativeBehavior();
    }
    String specString = _getStringArgument(node, 0);
    if (specString == null) {
      reporter.internalError(
          CURRENT_ELEMENT_SPANNABLE, "Unexpected first argument.");
      return new native.NativeBehavior();
    }
    return native.NativeBehavior.ofJsEmbeddedGlobalCall(
        specString,
        typeLookup(resolveAsRaw: true),
        CURRENT_ELEMENT_SPANNABLE,
        reporter,
        commonElements);
  }

  js.Name getNameForJsGetName(ConstantValue constant, Namer namer) {
    int index = extractEnumIndexFromConstantValue(
        constant, commonElements.jsGetNameEnum);
    if (index == null) return null;
    return namer.getNameForJsGetName(
        CURRENT_ELEMENT_SPANNABLE, JsGetName.values[index]);
  }

  int extractEnumIndexFromConstantValue(
      ConstantValue constant, ClassEntity classElement) {
    if (constant is ConstructedConstantValue) {
      if (constant.type.element == classElement) {
        assert(constant.fields.length == 1 || constant.fields.length == 2);
        ConstantValue indexConstant = constant.fields.values.first;
        if (indexConstant is IntConstantValue) {
          return indexConstant.intValue.toInt();
        }
      }
    }
    return null;
  }

  ConstantValue getConstantValue(ir.Expression node,
      {bool requireConstant: true,
      bool implicitNull: false,
      bool checkCasts: true}) {
    ConstantExpression constant;
    if (node == null) {
      if (!implicitNull) {
        throw failedAt(
            CURRENT_ELEMENT_SPANNABLE, 'No expression for constant.');
      }
      constant = new NullConstantExpression();
    } else {
      constant =
          new Constantifier(this, requireConstant: requireConstant).visit(node);
    }
    if (constant == null) {
      if (requireConstant) {
        throw new UnsupportedError(
            'No constant for ${DebugPrinter.prettyPrint(node)}');
      }
      return null;
    }
    ConstantValue value = computeConstantValue(
        computeSourceSpanFromTreeNode(node), constant,
        requireConstant: requireConstant, checkCasts: checkCasts);
    if (!value.isConstant && !requireConstant) {
      return null;
    }
    return value;
  }

  /// Converts [annotations] into a list of [ConstantValue]s.
  List<ConstantValue> getMetadata(List<ir.Expression> annotations) {
    if (annotations.isEmpty) return const <ConstantValue>[];
    List<ConstantValue> metadata = <ConstantValue>[];
    annotations.forEach((ir.Expression node) {
      // We skip the implicit cast checks for metadata to avoid circular
      // dependencies in the js-interop class registration.
      metadata.add(getConstantValue(node, checkCasts: false));
    });
    return metadata;
  }

  FunctionEntity getSuperNoSuchMethod(ClassEntity cls) {
    while (cls != null) {
      cls = elementEnvironment.getSuperClass(cls);
      MemberEntity member = elementEnvironment.lookupLocalClassMember(
          cls, Identifiers.noSuchMethod_);
      if (member != null && !member.isAbstract) {
        if (member.isFunction) {
          FunctionEntity function = member;
          if (function.parameterStructure.positionalParameters >= 1) {
            return function;
          }
        }
        // If [member] is not a valid `noSuchMethod` the target is
        // `Object.superNoSuchMethod`.
        break;
      }
    }
    FunctionEntity function = elementEnvironment.lookupLocalClassMember(
        commonElements.objectClass, Identifiers.noSuchMethod_);
    assert(function != null,
        failedAt(cls, "No super noSuchMethod found for class $cls."));
    return function;
  }

  Iterable<LibraryEntity> get libraryListInternal {
    if (env.length != libraryMap.length) {
      // Create a [KLibrary] for each library.
      env.forEachLibrary((KLibraryEnv env) {
        getLibraryInternal(env.library, env);
      });
    }
    return libraryMap.values;
  }

  LibraryEntity getLibraryInternal(ir.Library node, [KLibraryEnv libraryEnv]) {
    return libraryMap[node] ??= _getLibraryCreate(node, libraryEnv);
  }

  LibraryEntity _getLibraryCreate(ir.Library node, KLibraryEnv libraryEnv) {
    assert(
        !envIsClosed,
        "Environment of $this is closed. Trying to create "
        "library for $node.");
    Uri canonicalUri = node.importUri;
    String name = node.name;
    if (name == null) {
      // Use the file name as script name.
      String path = canonicalUri.path;
      name = path.substring(path.lastIndexOf('/') + 1);
    }
    IndexedLibrary library = createLibrary(name, canonicalUri);
    return libraries.register(library, new KLibraryData(node),
        libraryEnv ?? env.lookupLibrary(canonicalUri));
  }

  ClassEntity getClassInternal(ir.Class node, [KClassEnv classEnv]) {
    return classMap[node] ??= _getClassCreate(node, classEnv);
  }

  ClassEntity _getClassCreate(ir.Class node, KClassEnv classEnv) {
    assert(
        !envIsClosed,
        "Environment of $this is closed. Trying to create "
        "class for $node.");
    KLibrary library = getLibraryInternal(node.enclosingLibrary);
    if (classEnv == null) {
      classEnv = libraries.getEnv(library).lookupClass(node.name);
    }
    IndexedClass cls =
        createClass(library, node.name, isAbstract: node.isAbstract);
    return classes.register(cls, new KClassDataImpl(node), classEnv);
  }

  TypedefEntity getTypedefInternal(ir.Typedef node) {
    return typedefMap[node] ??= _getTypedefCreate(node);
  }

  TypedefEntity _getTypedefCreate(ir.Typedef node) {
    assert(
        !envIsClosed,
        "Environment of $this is closed. Trying to create "
        "typedef for $node.");
    IndexedLibrary library = getLibraryInternal(node.enclosingLibrary);
    IndexedTypedef typedef = createTypedef(library, node.name);
    TypedefType typedefType = new TypedefType(
        typedef,
        new List<DartType>.filled(
            node.typeParameters.length, const DynamicType()),
        getDartType(node.type));
    return typedefs.register(
        typedef, new KTypedefData(node, typedef, typedefType));
  }

  TypeVariableEntity getTypeVariableInternal(ir.TypeParameter node) {
    return typeVariableMap[node] ??= _getTypeVariableCreate(node);
  }

  TypeVariableEntity _getTypeVariableCreate(ir.TypeParameter node) {
    assert(
        !envIsClosed,
        "Environment of $this is closed. Trying to create "
        "type variable for $node.");
    if (node.parent is ir.Class) {
      ir.Class cls = node.parent;
      int index = cls.typeParameters.indexOf(node);
      return typeVariables.register(
          createTypeVariable(getClassInternal(cls), node.name, index),
          new KTypeVariableData(node));
    }
    if (node.parent is ir.FunctionNode) {
      ir.FunctionNode func = node.parent;
      int index = func.typeParameters.indexOf(node);
      if (func.parent is ir.Constructor) {
        ir.Constructor constructor = func.parent;
        ir.Class cls = constructor.enclosingClass;
        return getTypeVariableInternal(cls.typeParameters[index]);
      } else if (func.parent is ir.Procedure) {
        ir.Procedure procedure = func.parent;
        if (procedure.kind == ir.ProcedureKind.Factory) {
          ir.Class cls = procedure.enclosingClass;
          return getTypeVariableInternal(cls.typeParameters[index]);
        } else {
          return typeVariables.register(
              createTypeVariable(
                  getMethodInternal(procedure), node.name, index),
              new KTypeVariableData(node));
        }
      } else if (func.parent is ir.FunctionDeclaration ||
          func.parent is ir.FunctionExpression) {
        // Ensure that local function type variables have been created.
        getLocalFunction(func.parent);
        return typeVariableMap[node];
      } else {
        throw new UnsupportedError('Unsupported function type parameter parent '
            'node ${func.parent}.');
      }
    }
    throw new UnsupportedError('Unsupported type parameter type node $node.');
  }

  ConstructorEntity getConstructorInternal(ir.Member node) {
    return constructorMap[node] ??= _getConstructorCreate(node);
  }

  ConstructorEntity _getConstructorCreate(ir.Member node) {
    assert(
        !envIsClosed,
        "Environment of $this is closed. Trying to create "
        "constructor for $node.");
    ir.FunctionNode functionNode;
    ClassEntity enclosingClass = getClassInternal(node.enclosingClass);
    Name name = getName(node.name);
    bool isExternal = node.isExternal;

    IndexedConstructor constructor;
    if (node is ir.Constructor) {
      functionNode = node.function;
      constructor = createGenerativeConstructor(enclosingClass, name,
          getParameterStructure(functionNode, includeTypeParameters: false),
          isExternal: isExternal, isConst: node.isConst);
    } else if (node is ir.Procedure) {
      functionNode = node.function;
      bool isFromEnvironment = isExternal &&
          name.text == 'fromEnvironment' &&
          const ['int', 'bool', 'String'].contains(enclosingClass.name);
      constructor = createFactoryConstructor(enclosingClass, name,
          getParameterStructure(functionNode, includeTypeParameters: false),
          isExternal: isExternal,
          isConst: node.isConst,
          isFromEnvironmentConstructor: isFromEnvironment);
    } else {
      // TODO(johnniwinther): Convert `node.location` to a [SourceSpan].
      throw failedAt(
          NO_LOCATION_SPANNABLE, "Unexpected constructor node: ${node}.");
    }
    return members.register<IndexedConstructor, KConstructorData>(
        constructor, new KConstructorDataImpl(node, functionNode));
  }

  FunctionEntity getMethodInternal(ir.Procedure node) {
    // [_getMethodCreate] inserts the created function in [methodMap] so we
    // don't need to use ??= here.
    return methodMap[node] ?? _getMethodCreate(node);
  }

  FunctionEntity _getMethodCreate(ir.Procedure node) {
    assert(
        !envIsClosed,
        "Environment of $this is closed. Trying to create "
        "function for $node.");
    FunctionEntity function;
    LibraryEntity library;
    ClassEntity enclosingClass;
    if (node.enclosingClass != null) {
      enclosingClass = getClassInternal(node.enclosingClass);
      library = enclosingClass.library;
    } else {
      library = getLibraryInternal(node.enclosingLibrary);
    }
    Name name = getName(node.name);
    bool isStatic = node.isStatic;
    bool isExternal = node.isExternal;
    // TODO(johnniwinther): Remove `&& !node.isExternal` when #31233 is fixed.
    bool isAbstract = node.isAbstract && !node.isExternal;
    AsyncMarker asyncMarker = getAsyncMarker(node.function);
    switch (node.kind) {
      case ir.ProcedureKind.Factory:
        throw new UnsupportedError("Cannot create method from factory.");
      case ir.ProcedureKind.Getter:
        function = createGetter(library, enclosingClass, name, asyncMarker,
            isStatic: isStatic, isExternal: isExternal, isAbstract: isAbstract);
        break;
      case ir.ProcedureKind.Method:
      case ir.ProcedureKind.Operator:
        function = createMethod(library, enclosingClass, name,
            getParameterStructure(node.function), asyncMarker,
            isStatic: isStatic, isExternal: isExternal, isAbstract: isAbstract);
        break;
      case ir.ProcedureKind.Setter:
        assert(asyncMarker == AsyncMarker.SYNC);
        function = createSetter(library, enclosingClass, name.setter,
            isStatic: isStatic, isExternal: isExternal, isAbstract: isAbstract);
        break;
    }
    members.register<IndexedFunction, KFunctionData>(
        function, new KFunctionDataImpl(node, node.function));
    // We need to register the function before creating the type variables.
    methodMap[node] = function;
    for (ir.TypeParameter typeParameter in node.function.typeParameters) {
      getTypeVariable(typeParameter);
    }
    return function;
  }

  FieldEntity getFieldInternal(ir.Field node) {
    return fieldMap[node] ??= _getFieldCreate(node);
  }

  FieldEntity _getFieldCreate(ir.Field node) {
    assert(
        !envIsClosed,
        "Environment of $this is closed. Trying to create "
        "field for $node.");
    LibraryEntity library;
    ClassEntity enclosingClass;
    if (node.enclosingClass != null) {
      enclosingClass = getClassInternal(node.enclosingClass);
      library = enclosingClass.library;
    } else {
      library = getLibraryInternal(node.enclosingLibrary);
    }
    Name name = getName(node.name);
    bool isStatic = node.isStatic;
    IndexedField field = createField(library, enclosingClass, name,
        isStatic: isStatic,
        isAssignable: node.isMutable,
        isConst: node.isConst);
    return members.register<IndexedField, KFieldData>(
        field, new KFieldDataImpl(node));
  }

  bool checkFamily(Entity entity) {
    assert(
        '$entity'.startsWith(kElementPrefix),
        failedAt(entity,
            "Unexpected entity $entity, expected family $kElementPrefix."));
    return true;
  }

  /// NativeBasicData is need for computation of the default super class.
  NativeBasicData get nativeBasicData => _frontendStrategy.nativeBasicData;

  /// Adds libraries in [component] to the set of libraries.
  ///
  /// The main method of the first component is used as the main method for the
  /// compilation.
  void addComponent(ir.Component component) {
    env.addComponent(component);
  }

  native.BehaviorBuilder get nativeBehaviorBuilder =>
      _nativeBehaviorBuilder ??= new KernelBehaviorBuilder(elementEnvironment,
          commonElements, nativeBasicData, reporter, options);

  ResolutionImpact computeWorldImpact(KMember member) {
    ir.Member node = members.getData(member).node;
    KernelImpactBuilder builder =
        new KernelImpactBuilder(this, member, reporter, options);
    node.accept(builder);
    if (retainDataForTesting) {
      staticTypeCacheForTesting ??= {};
      staticTypeCacheForTesting[member] = builder.staticTypeCacheForTesting;
    }
    return builder.impactBuilder;
  }

  ScopeModel computeScopeModel(KMember member) {
    ir.Member node = members.getData(member).node;
    return ScopeModel.computeScopeModel(node);
  }

  /// Returns the kernel [ir.Procedure] node for the [method].
  ir.Procedure _lookupProcedure(KFunction method) {
    return members.getData(method).node;
  }

  @override
  ir.Library getLibraryNode(LibraryEntity library) {
    return libraries.getData(library).library;
  }

  @override
  Local getLocalFunction(ir.TreeNode node) {
    assert(
        node is ir.FunctionDeclaration || node is ir.FunctionExpression,
        failedAt(
            CURRENT_ELEMENT_SPANNABLE, 'Invalid local function node: $node'));
    KLocalFunction localFunction = localFunctionMap[node];
    if (localFunction == null) {
      MemberEntity memberContext;
      Entity executableContext;
      ir.TreeNode parent = node.parent;
      while (parent != null) {
        if (parent is ir.Member) {
          executableContext = memberContext = getMember(parent);
          break;
        }
        if (parent is ir.FunctionDeclaration ||
            parent is ir.FunctionExpression) {
          KLocalFunction localFunction = getLocalFunction(parent);
          executableContext = localFunction;
          memberContext = localFunction.memberContext;
          break;
        }
        parent = parent.parent;
      }
      String name;
      ir.FunctionNode function;
      if (node is ir.FunctionDeclaration) {
        name = node.variable.name;
        function = node.function;
      } else if (node is ir.FunctionExpression) {
        function = node.function;
      }
      localFunction = localFunctionMap[node] =
          new KLocalFunction(name, memberContext, executableContext, node);
      int index = 0;
      List<KLocalTypeVariable> typeVariables = <KLocalTypeVariable>[];
      for (ir.TypeParameter typeParameter in function.typeParameters) {
        typeVariables.add(typeVariableMap[typeParameter] =
            new KLocalTypeVariable(localFunction, typeParameter.name, index));
        index++;
      }
      index = 0;
      for (ir.TypeParameter typeParameter in function.typeParameters) {
        typeVariables[index].bound = getDartType(typeParameter.bound);
        typeVariables[index].defaultType =
            getDartType(typeParameter.defaultType);
        index++;
      }
      localFunction.functionType = getFunctionType(function);
    }
    return localFunction;
  }

  bool _implementsFunction(IndexedClass cls) {
    assert(checkFamily(cls));
    KClassData data = classes.getData(cls);
    OrderedTypeSet orderedTypeSet = data.orderedTypeSet;
    InterfaceType supertype = orderedTypeSet.asInstanceOf(
        commonElements.functionClass,
        getHierarchyDepth(commonElements.functionClass));
    if (supertype != null) {
      return true;
    }
    return data.callType is FunctionType;
  }

  @override
  ir.Typedef getTypedefNode(TypedefEntity typedef) {
    return _getTypedefNode(typedef);
  }

  /// Returns the element type of a async/sync*/async* function.
  @override
  DartType getFunctionAsyncOrSyncStarElementType(ir.FunctionNode functionNode) {
    DartType returnType = getDartType(functionNode.returnType);
    switch (functionNode.asyncMarker) {
      case ir.AsyncMarker.SyncStar:
        return elementEnvironment.getAsyncOrSyncStarElementType(
            AsyncMarker.SYNC_STAR, returnType);
      case ir.AsyncMarker.Async:
        return elementEnvironment.getAsyncOrSyncStarElementType(
            AsyncMarker.ASYNC, returnType);
      case ir.AsyncMarker.AsyncStar:
        return elementEnvironment.getAsyncOrSyncStarElementType(
            AsyncMarker.ASYNC_STAR, returnType);
      default:
        failedAt(CURRENT_ELEMENT_SPANNABLE,
            "Unexpected ir.AsyncMarker: ${functionNode.asyncMarker}");
    }
    return null;
  }

  /// Returns `true` is [node] has a `@Native(...)` annotation.
  // TODO(johnniwinther): Cache this for later use.
  bool isNativeClass(ir.Class node) {
    for (ir.Expression annotation in node.annotations) {
      if (annotation is ir.ConstructorInvocation) {
        FunctionEntity target = getConstructor(annotation.target);
        if (target.enclosingClass == commonElements.nativeAnnotationClass) {
          return true;
        }
      }
    }
    return false;
  }

  /// Compute the kind of foreign helper function called by [node], if any.
  ForeignKind getForeignKind(ir.StaticInvocation node) {
    if (commonElements.isForeignHelper(getMember(node.target))) {
      switch (node.target.name.name) {
        case JavaScriptBackend.JS:
          return ForeignKind.JS;
        case JavaScriptBackend.JS_BUILTIN:
          return ForeignKind.JS_BUILTIN;
        case JavaScriptBackend.JS_EMBEDDED_GLOBAL:
          return ForeignKind.JS_EMBEDDED_GLOBAL;
        case JavaScriptBackend.JS_INTERCEPTOR_CONSTANT:
          return ForeignKind.JS_INTERCEPTOR_CONSTANT;
      }
    }
    return ForeignKind.NONE;
  }

  /// Computes the [InterfaceType] referenced by a call to the
  /// [JS_INTERCEPTOR_CONSTANT] function, if any.
  InterfaceType getInterfaceTypeForJsInterceptorCall(ir.StaticInvocation node) {
    if (node.arguments.positional.length != 1 ||
        node.arguments.named.isNotEmpty) {
      reporter.reportErrorMessage(CURRENT_ELEMENT_SPANNABLE,
          MessageKind.WRONG_ARGUMENT_FOR_JS_INTERCEPTOR_CONSTANT);
    }
    ir.Node argument = node.arguments.positional.first;
    if (argument is ir.TypeLiteral && argument.type is ir.InterfaceType) {
      return getInterfaceType(argument.type);
    }
    return null;
  }

  /// Computes the native behavior for reading the native [field].
  // TODO(johnniwinther): Cache this for later use.
  native.NativeBehavior getNativeBehaviorForFieldLoad(ir.Field field,
      {bool isJsInterop}) {
    DartType type = getDartType(field.type);
    List<ConstantValue> metadata = getMetadata(field.annotations);
    return nativeBehaviorBuilder.buildFieldLoadBehavior(
        type, metadata, typeLookup(resolveAsRaw: false),
        isJsInterop: isJsInterop);
  }

  /// Computes the native behavior for writing to the native [field].
  // TODO(johnniwinther): Cache this for later use.
  native.NativeBehavior getNativeBehaviorForFieldStore(ir.Field field) {
    DartType type = getDartType(field.type);
    return nativeBehaviorBuilder.buildFieldStoreBehavior(type);
  }

  /// Computes the native behavior for calling [member].
  // TODO(johnniwinther): Cache this for later use.
  native.NativeBehavior getNativeBehaviorForMethod(ir.Member member,
      {bool isJsInterop}) {
    DartType type;
    if (member is ir.Procedure) {
      type = getFunctionType(member.function);
    } else if (member is ir.Constructor) {
      type = getFunctionType(member.function);
    } else {
      failedAt(CURRENT_ELEMENT_SPANNABLE, "Unexpected method node $member.");
    }
    List<ConstantValue> metadata = getMetadata(member.annotations);
    return nativeBehaviorBuilder.buildMethodBehavior(
        type, metadata, typeLookup(resolveAsRaw: false),
        isJsInterop: isJsInterop);
  }

  IndexedLibrary createLibrary(String name, Uri canonicalUri) {
    return new KLibrary(name, canonicalUri);
  }

  IndexedClass createClass(LibraryEntity library, String name,
      {bool isAbstract}) {
    return new KClass(library, name, isAbstract: isAbstract);
  }

  IndexedTypedef createTypedef(LibraryEntity library, String name) {
    return new KTypedef(library, name);
  }

  TypeVariableEntity createTypeVariable(
      Entity typeDeclaration, String name, int index) {
    return new KTypeVariable(typeDeclaration, name, index);
  }

  IndexedConstructor createGenerativeConstructor(ClassEntity enclosingClass,
      Name name, ParameterStructure parameterStructure,
      {bool isExternal, bool isConst}) {
    return new KGenerativeConstructor(enclosingClass, name, parameterStructure,
        isExternal: isExternal, isConst: isConst);
  }

  IndexedConstructor createFactoryConstructor(ClassEntity enclosingClass,
      Name name, ParameterStructure parameterStructure,
      {bool isExternal, bool isConst, bool isFromEnvironmentConstructor}) {
    return new KFactoryConstructor(enclosingClass, name, parameterStructure,
        isExternal: isExternal,
        isConst: isConst,
        isFromEnvironmentConstructor: isFromEnvironmentConstructor);
  }

  IndexedFunction createGetter(LibraryEntity library,
      ClassEntity enclosingClass, Name name, AsyncMarker asyncMarker,
      {bool isStatic, bool isExternal, bool isAbstract}) {
    return new KGetter(library, enclosingClass, name, asyncMarker,
        isStatic: isStatic, isExternal: isExternal, isAbstract: isAbstract);
  }

  IndexedFunction createMethod(
      LibraryEntity library,
      ClassEntity enclosingClass,
      Name name,
      ParameterStructure parameterStructure,
      AsyncMarker asyncMarker,
      {bool isStatic,
      bool isExternal,
      bool isAbstract}) {
    return new KMethod(
        library, enclosingClass, name, parameterStructure, asyncMarker,
        isStatic: isStatic, isExternal: isExternal, isAbstract: isAbstract);
  }

  IndexedFunction createSetter(
      LibraryEntity library, ClassEntity enclosingClass, Name name,
      {bool isStatic, bool isExternal, bool isAbstract}) {
    return new KSetter(library, enclosingClass, name,
        isStatic: isStatic, isExternal: isExternal, isAbstract: isAbstract);
  }

  IndexedField createField(
      LibraryEntity library, ClassEntity enclosingClass, Name name,
      {bool isStatic, bool isAssignable, bool isConst}) {
    return new KField(library, enclosingClass, name,
        isStatic: isStatic, isAssignable: isAssignable, isConst: isConst);
  }
}

class KernelElementEnvironment extends ElementEnvironment
    implements KElementEnvironment {
  final KernelToElementMapImpl elementMap;

  KernelElementEnvironment(this.elementMap);

  @override
  DartType get dynamicType => const DynamicType();

  @override
  LibraryEntity get mainLibrary => elementMap._mainLibrary;

  @override
  FunctionEntity get mainFunction => elementMap._mainFunction;

  @override
  Iterable<LibraryEntity> get libraries => elementMap.libraryListInternal;

  @override
  String getLibraryName(LibraryEntity library) {
    return elementMap._getLibraryName(library);
  }

  @override
  InterfaceType getThisType(ClassEntity cls) {
    return elementMap.getThisType(cls);
  }

  @override
  InterfaceType getRawType(ClassEntity cls) {
    return elementMap._getRawType(cls);
  }

  @override
  bool isGenericClass(ClassEntity cls) {
    return getThisType(cls).typeArguments.isNotEmpty;
  }

  @override
  bool isMixinApplication(ClassEntity cls) {
    return elementMap._isMixinApplication(cls);
  }

  @override
  bool isUnnamedMixinApplication(ClassEntity cls) {
    return elementMap._isUnnamedMixinApplication(cls);
  }

  @override
  DartType getTypeVariableBound(TypeVariableEntity typeVariable) {
    if (typeVariable is KLocalTypeVariable) return typeVariable.bound;
    return elementMap.getTypeVariableBound(typeVariable);
  }

  @override
  InterfaceType createInterfaceType(
      ClassEntity cls, List<DartType> typeArguments) {
    return new InterfaceType(cls, typeArguments);
  }

  @override
  FunctionType getFunctionType(FunctionEntity function) {
    return elementMap._getFunctionType(function);
  }

  @override
  List<TypeVariableType> getFunctionTypeVariables(FunctionEntity function) {
    return elementMap._getFunctionTypeVariables(function);
  }

  @override
  DartType getFunctionAsyncOrSyncStarElementType(FunctionEntity function) {
    // TODO(sra): Should be getting the DartType from the node.
    DartType returnType = getFunctionType(function).returnType;
    return getAsyncOrSyncStarElementType(function.asyncMarker, returnType);
  }

  @override
  DartType getAsyncOrSyncStarElementType(
      AsyncMarker asyncMarker, DartType returnType) {
    switch (asyncMarker) {
      case AsyncMarker.SYNC:
        return returnType;
      case AsyncMarker.SYNC_STAR:
        if (returnType is InterfaceType) {
          if (returnType.element == elementMap.commonElements.iterableClass) {
            return returnType.typeArguments.first;
          }
        }
        return dynamicType;
      case AsyncMarker.ASYNC:
        if (returnType is FutureOrType) return returnType.typeArgument;
        if (returnType is InterfaceType) {
          if (returnType.element == elementMap.commonElements.futureClass) {
            return returnType.typeArguments.first;
          }
        }
        return dynamicType;
      case AsyncMarker.ASYNC_STAR:
        if (returnType is InterfaceType) {
          if (returnType.element == elementMap.commonElements.streamClass) {
            return returnType.typeArguments.first;
          }
        }
        return dynamicType;
    }
    assert(false, 'Unexpected marker ${asyncMarker}');
    return null;
  }

  @override
  DartType getFieldType(FieldEntity field) {
    return elementMap._getFieldType(field);
  }

  @override
  FunctionType getLocalFunctionType(covariant KLocalFunction function) {
    return function.functionType;
  }

  @override
  ConstantExpression getFieldConstantForTesting(FieldEntity field) {
    return elementMap._getFieldConstantExpression(field);
  }

  @override
  DartType getUnaliasedType(DartType type) => type;

  @override
  ConstructorEntity lookupConstructor(ClassEntity cls, String name,
      {bool required: false}) {
    ConstructorEntity constructor = elementMap.lookupConstructor(cls, name);
    if (constructor == null && required) {
      throw failedAt(
          CURRENT_ELEMENT_SPANNABLE,
          "The constructor '$name' was not found in class '${cls.name}' "
          "in library ${cls.library.canonicalUri}.");
    }
    return constructor;
  }

  @override
  MemberEntity lookupLocalClassMember(ClassEntity cls, String name,
      {bool setter: false, bool required: false}) {
    MemberEntity member =
        elementMap.lookupClassMember(cls, name, setter: setter);
    if (member == null && required) {
      throw failedAt(CURRENT_ELEMENT_SPANNABLE,
          "The member '$name' was not found in ${cls.name}.");
    }
    return member;
  }

  @override
  ClassEntity getSuperClass(ClassEntity cls,
      {bool skipUnnamedMixinApplications: false}) {
    assert(elementMap.checkFamily(cls));
    ClassEntity superclass = elementMap.getSuperType(cls)?.element;
    if (skipUnnamedMixinApplications) {
      while (superclass != null &&
          elementMap._isUnnamedMixinApplication(superclass)) {
        superclass = elementMap.getSuperType(superclass)?.element;
      }
    }
    return superclass;
  }

  @override
  void forEachSupertype(ClassEntity cls, void f(InterfaceType supertype)) {
    elementMap._forEachSupertype(cls, f);
  }

  @override
  void forEachMixin(ClassEntity cls, void f(ClassEntity mixin)) {
    elementMap._forEachMixin(cls, f);
  }

  @override
  void forEachLocalClassMember(ClassEntity cls, void f(MemberEntity member)) {
    elementMap._forEachLocalClassMember(cls, f);
  }

  @override
  void forEachClassMember(
      ClassEntity cls, void f(ClassEntity declarer, MemberEntity member)) {
    elementMap._forEachClassMember(cls, f);
  }

  @override
  void forEachConstructor(
      ClassEntity cls, void f(ConstructorEntity constructor)) {
    elementMap._forEachConstructor(cls, f);
  }

  @override
  void forEachLibraryMember(
      LibraryEntity library, void f(MemberEntity member)) {
    elementMap._forEachLibraryMember(library, f);
  }

  @override
  MemberEntity lookupLibraryMember(LibraryEntity library, String name,
      {bool setter: false, bool required: false}) {
    MemberEntity member =
        elementMap.lookupLibraryMember(library, name, setter: setter);
    if (member == null && required) {
      failedAt(CURRENT_ELEMENT_SPANNABLE,
          "The member '${name}' was not found in library '${library.name}'.");
    }
    return member;
  }

  @override
  ClassEntity lookupClass(LibraryEntity library, String name,
      {bool required: false}) {
    ClassEntity cls = elementMap.lookupClass(library, name);
    if (cls == null && required) {
      failedAt(CURRENT_ELEMENT_SPANNABLE,
          "The class '$name'  was not found in library '${library.name}'.");
    }
    return cls;
  }

  @override
  void forEachClass(LibraryEntity library, void f(ClassEntity cls)) {
    elementMap._forEachClass(library, f);
  }

  @override
  LibraryEntity lookupLibrary(Uri uri, {bool required: false}) {
    LibraryEntity library = elementMap.lookupLibrary(uri);
    if (library == null && required) {
      failedAt(CURRENT_ELEMENT_SPANNABLE, "The library '$uri' was not found.");
    }
    return library;
  }

  @override
  bool isDeferredLoadLibraryGetter(MemberEntity member) {
    // The front-end generates the getter of loadLibrary explicitly as code
    // so there is no implicit representation based on a "loadLibrary" member.
    return false;
  }

  @override
  Iterable<ConstantValue> getLibraryMetadata(covariant IndexedLibrary library) {
    assert(elementMap.checkFamily(library));
    KLibraryData libraryData = elementMap.libraries.getData(library);
    return libraryData.getMetadata(elementMap);
  }

  @override
  Iterable<ImportEntity> getImports(covariant IndexedLibrary library) {
    assert(elementMap.checkFamily(library));
    KLibraryData libraryData = elementMap.libraries.getData(library);
    return libraryData.getImports(elementMap);
  }

  @override
  Iterable<ConstantValue> getClassMetadata(covariant IndexedClass cls) {
    assert(elementMap.checkFamily(cls));
    KClassData classData = elementMap.classes.getData(cls);
    return classData.getMetadata(elementMap);
  }

  @override
  Iterable<ConstantValue> getMemberMetadata(covariant IndexedMember member,
      {bool includeParameterMetadata: false}) {
    // TODO(redemption): Support includeParameterMetadata.
    assert(elementMap.checkFamily(member));
    KMemberData memberData = elementMap.members.getData(member);
    return memberData.getMetadata(elementMap);
  }

  @override
  bool isEnumClass(ClassEntity cls) {
    assert(elementMap.checkFamily(cls));
    KClassData classData = elementMap.classes.getData(cls);
    return classData.isEnumClass;
  }
}

/// [native.BehaviorBuilder] for kernel based elements.
class KernelBehaviorBuilder extends native.BehaviorBuilder {
  final ElementEnvironment elementEnvironment;
  final CommonElements commonElements;
  final DiagnosticReporter reporter;
  final NativeBasicData nativeBasicData;
  final CompilerOptions _options;

  KernelBehaviorBuilder(this.elementEnvironment, this.commonElements,
      this.nativeBasicData, this.reporter, this._options);

  @override
  bool get trustJSInteropTypeAnnotations =>
      _options.trustJSInteropTypeAnnotations;
}

/// Constant environment mapping [ConstantExpression]s to [ConstantValue]s using
/// [_EvaluationEnvironment] for the evaluation.
class KernelConstantEnvironment implements ConstantEnvironment {
  final KernelToElementMapImpl _elementMap;
  final Environment _environment;

  Map<ConstantExpression, ConstantValue> _valueMap =
      <ConstantExpression, ConstantValue>{};

  KernelConstantEnvironment(this._elementMap, this._environment);

  @override
  ConstantSystem get constantSystem => JavaScriptConstantSystem.only;

  ConstantValue _getConstantValue(
      Spannable spannable, ConstantExpression expression,
      {bool constantRequired, bool checkCasts: true}) {
    return _valueMap.putIfAbsent(expression, () {
      return expression.evaluate(
          new KernelEvaluationEnvironment(_elementMap, _environment, spannable,
              constantRequired: constantRequired, checkCasts: checkCasts),
          constantSystem);
    });
  }
}

/// Evaluation environment used for computing [ConstantValue]s for
/// kernel based [ConstantExpression]s.
class KernelEvaluationEnvironment extends EvaluationEnvironmentBase {
  final KernelToElementMapImpl _elementMap;
  final Environment _environment;
  final bool checkCasts;

  KernelEvaluationEnvironment(
      this._elementMap, this._environment, Spannable spannable,
      {bool constantRequired, this.checkCasts: true})
      : super(spannable, constantRequired: constantRequired);

  @override
  CommonElements get commonElements => _elementMap.commonElements;

  @override
  DartTypes get types => _elementMap.types;

  @override
  DartType substByContext(DartType base, InterfaceType target) {
    return _elementMap.substByContext(base, target);
  }

  @override
  ConstantConstructor getConstructorConstant(ConstructorEntity constructor) {
    return _elementMap._getConstructorConstant(constructor);
  }

  @override
  ConstantExpression getFieldConstant(FieldEntity field) {
    return _elementMap._getFieldConstantExpression(field);
  }

  @override
  ConstantExpression getLocalConstant(Local local) {
    throw new UnimplementedError("_EvaluationEnvironment.getLocalConstant");
  }

  @override
  String readFromEnvironment(String name) {
    return _environment.valueOf(name);
  }

  @override
  DiagnosticReporter get reporter => _elementMap.reporter;

  @override
  bool get enableAssertions => _elementMap.options.enableUserAssertions;
}

class KernelNativeMemberResolver extends NativeMemberResolverBase {
  final KernelToElementMap elementMap;
  final NativeBasicData nativeBasicData;
  final NativeDataBuilder nativeDataBuilder;

  KernelNativeMemberResolver(
      this.elementMap, this.nativeBasicData, this.nativeDataBuilder);

  @override
  KElementEnvironment get elementEnvironment => elementMap.elementEnvironment;

  @override
  CommonElements get commonElements => elementMap.commonElements;

  @override
  native.NativeBehavior computeNativeFieldStoreBehavior(
      covariant KField field) {
    ir.Field node = elementMap.getMemberNode(field);
    return elementMap.getNativeBehaviorForFieldStore(node);
  }

  @override
  native.NativeBehavior computeNativeFieldLoadBehavior(covariant KField field,
      {bool isJsInterop}) {
    ir.Field node = elementMap.getMemberNode(field);
    return elementMap.getNativeBehaviorForFieldLoad(node,
        isJsInterop: isJsInterop);
  }

  @override
  native.NativeBehavior computeNativeMethodBehavior(
      covariant KFunction function,
      {bool isJsInterop}) {
    ir.Member node = elementMap.getMemberNode(function);
    return elementMap.getNativeBehaviorForMethod(node,
        isJsInterop: isJsInterop);
  }

  @override
  bool isNativeMethod(covariant KFunction function) {
    if (!native.maybeEnableNative(function.library.canonicalUri)) return false;
    ir.Member node = elementMap.getMemberNode(function);
    return node.annotations.any((ir.Expression expression) {
      return expression is ir.ConstructorInvocation &&
          elementMap.getInterfaceType(expression.constructedType) ==
              commonElements.externalNameType;
    });
  }

  @override
  bool isJsInteropMember(MemberEntity element) {
    return nativeBasicData.isJsInteropMember(element);
  }
}

class KernelClassQueries extends ClassQueries {
  final KernelToElementMapImpl elementMap;

  KernelClassQueries(this.elementMap);

  @override
  ClassEntity getDeclaration(ClassEntity cls) {
    return cls;
  }

  @override
  Iterable<InterfaceType> getSupertypes(ClassEntity cls) {
    return elementMap.getOrderedTypeSet(cls).supertypes;
  }

  @override
  ClassEntity getSuperClass(ClassEntity cls) {
    return elementMap.getSuperType(cls)?.element;
  }

  @override
  bool implementsFunction(ClassEntity cls) {
    return elementMap._implementsFunction(cls);
  }

  @override
  int getHierarchyDepth(ClassEntity cls) {
    return elementMap.getHierarchyDepth(cls);
  }

  @override
  ClassEntity getAppliedMixin(ClassEntity cls) {
    return elementMap.getAppliedMixin(cls);
  }
}
