// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart2js.js_emitter.type_test_registry;

import '../compiler.dart' show Compiler;
import '../elements/resolution_types.dart'
    show
        ResolutionDartType,
        ResolutionFunctionType,
        ResolutionInterfaceType,
        Types,
        ResolutionTypeVariableType;
import '../elements/elements.dart'
    show ClassElement, Element, ElementKind, MemberElement, MethodElement;
import '../js_backend/js_backend.dart'
    show JavaScriptBackend, RuntimeTypesSubstitutions, TypeChecks;
import '../world.dart' show ClosedWorld;

class TypeTestRegistry {
  /**
   * Raw ClassElement symbols occuring in is-checks and type assertions.  If the
   * program contains parameterized checks `x is Set<int>` and
   * `x is Set<String>` then the ClassElement `Set` will occur once in
   * [checkedClasses].
   */
  Set<ClassElement> checkedClasses;

  /**
   * The set of function types that checked, both explicity through tests of
   * typedefs and implicitly through type annotations in checked mode.
   */
  Set<ResolutionFunctionType> checkedFunctionTypes;

  /// Initially contains all classes that need RTI. After
  /// [computeNeededClasses]
  /// this set only contains classes that are only used for RTI.
  final Set<ClassElement> rtiNeededClasses = new Set<ClassElement>();

  Iterable<ClassElement> cachedClassesUsingTypeVariableTests;

  Iterable<ClassElement> get classesUsingTypeVariableTests {
    if (cachedClassesUsingTypeVariableTests == null) {
      cachedClassesUsingTypeVariableTests = compiler
          .codegenWorldBuilder.isChecks
          .where((ResolutionDartType t) => t is ResolutionTypeVariableType)
          .map((ResolutionTypeVariableType v) => v.element.enclosingClass)
          .toList();
    }
    return cachedClassesUsingTypeVariableTests;
  }

  final Compiler compiler;
  final ClosedWorld closedWorld;

  TypeTestRegistry(this.compiler, this.closedWorld);

  JavaScriptBackend get backend => compiler.backend;

  /**
   * Returns the classes with constructors used as a 'holder' in
   * [emitRuntimeTypeSupport].
   * TODO(9556): Some cases will go away when the class objects are created as
   * complete.  Not all classes will go away while constructors are referenced
   * from type substitutions.
   */
  Set<ClassElement> computeClassesModifiedByEmitRuntimeTypeSupport() {
    TypeChecks typeChecks = backend.rtiChecks.requiredChecks;
    Set<ClassElement> result = new Set<ClassElement>();
    for (ClassElement cls in typeChecks.classes) {
      if (typeChecks[cls].isNotEmpty) result.add(cls);
    }
    return result;
  }

  Set<ClassElement> computeRtiNeededClasses() {
    void addClassWithSuperclasses(ClassElement cls) {
      rtiNeededClasses.add(cls);
      for (ClassElement superclass = cls.superclass;
          superclass != null;
          superclass = superclass.superclass) {
        rtiNeededClasses.add(superclass);
      }
    }

    void addClassesWithSuperclasses(Iterable<ClassElement> classes) {
      for (ClassElement cls in classes) {
        addClassWithSuperclasses(cls);
      }
    }

    // 1.  Add classes that are referenced by type arguments or substitutions in
    //     argument checks.
    // TODO(karlklose): merge this case with 2 when unifying argument and
    // object checks.
    RuntimeTypesSubstitutions rtiSubstitutions = backend.rtiSubstitutions;
    backend.rtiChecks
        .getRequiredArgumentClasses()
        .forEach(addClassWithSuperclasses);

    // 2.  Add classes that are referenced by substitutions in object checks and
    //     their superclasses.
    TypeChecks requiredChecks =
        rtiSubstitutions.computeChecks(rtiNeededClasses, checkedClasses);
    Set<ClassElement> classesUsedInSubstitutions =
        rtiSubstitutions.getClassesUsedInSubstitutions(requiredChecks);
    addClassesWithSuperclasses(classesUsedInSubstitutions);

    // 3.  Add classes that contain checked generic function types. These are
    //     needed to store the signature encoding.
    for (ResolutionFunctionType type in checkedFunctionTypes) {
      ClassElement contextClass = Types.getClassContext(type);
      if (contextClass != null) {
        rtiNeededClasses.add(contextClass);
      }
    }

    bool canTearOff(Element function) {
      if (!function.isFunction ||
          function.isConstructor ||
          function.isAccessor) {
        return false;
      } else if (function.isInstanceMember) {
        if (!function.enclosingClass.isClosure) {
          return compiler.codegenWorldBuilder
              .hasInvokedGetter(function, closedWorld);
        }
      }
      return false;
    }

    bool canBeReflectedAsFunction(MemberElement element) {
      return element.kind == ElementKind.FUNCTION ||
          element.kind == ElementKind.GETTER ||
          element.kind == ElementKind.SETTER ||
          element.kind == ElementKind.GENERATIVE_CONSTRUCTOR;
    }

    bool canBeReified(MemberElement element) {
      return (canTearOff(element) ||
          backend.mirrorsData.isMemberAccessibleByReflection(element));
    }

    // Find all types referenced from the types of elements that can be
    // reflected on 'as functions'.
    backend.generatedCode.keys.where((element) {
      return canBeReflectedAsFunction(element) && canBeReified(element);
    }).forEach((MethodElement function) {
      ResolutionDartType type = function.type;
      for (ClassElement cls in backend.rtiChecks.getReferencedClasses(type)) {
        while (cls != null) {
          rtiNeededClasses.add(cls);
          cls = cls.superclass;
        }
      }
    });

    return rtiNeededClasses;
  }

  void computeRequiredTypeChecks() {
    assert(checkedClasses == null && checkedFunctionTypes == null);

    backend.rtiChecksBuilder.registerImplicitChecks(
        compiler.codegenWorldBuilder, classesUsingTypeVariableTests);
    backend.finalizeRti();

    checkedClasses = new Set<ClassElement>();
    checkedFunctionTypes = new Set<ResolutionFunctionType>();
    compiler.codegenWorldBuilder.isChecks.forEach((ResolutionDartType t) {
      if (t is ResolutionInterfaceType) {
        checkedClasses.add(t.element);
      } else if (t is ResolutionFunctionType) {
        checkedFunctionTypes.add(t);
      }
    });
  }
}
