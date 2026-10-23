package io.apkrun.fixture.systemservicestest;

import android.app.Activity;
import android.app.Instrumentation;
import android.os.Bundle;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/** T2 probe of the Guest Agent's actual SystemServices wrappers on the composed image (#36). */
public final class SystemServicesInstrumentation extends Instrumentation {
    private static final String WRAPPER_CLASS = "io.apkrun.guest.runtime.SystemServiceWrapper";
    private static final String REQUIREMENT_CLASS = "io.apkrun.guest.runtime.MethodRequirement";
    private static final String MISSING_METHOD_CLASS = "io.apkrun.guest.runtime.ServiceMethodMissing";
    private static final String SYSTEM_SERVICES_CLASS = "io.apkrun.guest.runtime.SystemServices";

    @Override
    public void onStart() {
        Bundle result = new Bundle();
        int resultCode = Activity.RESULT_OK;
        try {
            List<String> services = inspectImageWrappers();
            verifyMissingMethodIsolation();
            result.putString("stream", "APKRUN_SYSTEM_SERVICES_OK\n" + String.join("\n", services));
        } catch (Throwable error) {
            resultCode = Activity.RESULT_CANCELED;
            result.putString(
                "stream",
                "APKRUN_SYSTEM_SERVICES_FAILED " + error.getClass().getName() + ": " + error.getMessage()
            );
        }
        finish(resultCode, result);
    }

    private List<String> inspectImageWrappers() throws Exception {
        ClassLoader targetLoader = getTargetContext().getClassLoader();
        Class<?> servicesClass = Class.forName(SYSTEM_SERVICES_CLASS, true, targetLoader);
        Object services = servicesClass.getField("INSTANCE").get(null);
        @SuppressWarnings("unchecked")
        List<Object> wrappers = (List<Object>) servicesClass.getMethod("getAll").invoke(services);
        if (wrappers.isEmpty()) {
            throw new AssertionError("SystemServices.all returned no wrappers");
        }

        List<String> report = new ArrayList<>();
        List<String> failures = new ArrayList<>();
        for (Object wrapper : wrappers) {
            Class<?> wrapperClass = wrapper.getClass();
            String service = (String) wrapperClass.getMethod("getServiceName").invoke(wrapper);
            boolean available = (Boolean) wrapperClass.getMethod("getAvailable").invoke(wrapper);
            boolean servicePresent = wrapperClass.getMethod("getService").invoke(wrapper) != null;
            @SuppressWarnings("unchecked")
            List<String> missing = (List<String>) wrapperClass.getMethod("getMissingMethods").invoke(wrapper);
            report.add(
                "APKRUN_SYSTEM_SERVICE|" + service + "|" + available + "|" + servicePresent + "|"
                    + String.join(",", missing)
            );
            if (!available || !servicePresent || !missing.isEmpty()) {
                failures.add(service + " missing=" + String.join(",", missing));
            }
        }
        for (String line : report) {
            Bundle status = new Bundle();
            status.putString("stream", line);
            sendStatus(1, status);
        }
        if (!failures.isEmpty()) {
            throw new AssertionError("system service wrappers did not resolve: " + String.join("; ", failures));
        }
        return report;
    }

    private void verifyMissingMethodIsolation() throws Exception {
        ClassLoader targetLoader = getTargetContext().getClassLoader();
        Class<?> wrapperClass = Class.forName(WRAPPER_CLASS, true, targetLoader);
        Class<?> requirementClass = Class.forName(REQUIREMENT_CLASS, true, targetLoader);
        Class<?> missingMethodClass = Class.forName(MISSING_METHOD_CLASS, true, targetLoader);
        Class<?> function2Class = Class.forName("kotlin.jvm.functions.Function2", true, targetLoader);

        Object size = requirement(requirementClass, "size");
        Object missing = requirement(requirementClass, "apkrunMissingFrameworkMethod");
        Object broken = wrapper(
            wrapperClass,
            function2Class,
            targetLoader,
            "broken",
            Arrays.asList(size, missing)
        );
        Object healthy = wrapper(
            wrapperClass,
            function2Class,
            targetLoader,
            "healthy",
            Collections.singletonList(requirement(requirementClass, "size"))
        );

        if ((Boolean) wrapperClass.getMethod("getAvailable").invoke(broken)) {
            throw new AssertionError("a wrapper with a missing method reported available");
        }
        if (!(Boolean) wrapperClass.getMethod("supports", String.class).invoke(broken, "size")) {
            throw new AssertionError("a missing method disabled a different method in the same wrapper");
        }
        if ((Boolean) wrapperClass.getMethod("supports", String.class).invoke(
            broken, "apkrunMissingFrameworkMethod"
        )) {
            throw new AssertionError("the missing method was reported as supported");
        }
        if (!wrapperClass.getMethod("getMissingMethods").invoke(broken).equals(
            Collections.singletonList("apkrunMissingFrameworkMethod")
        )) {
            throw new AssertionError("the wrapper did not report the missing method precisely");
        }
        Object sizeResult = wrapperClass.getMethod("call", String.class, Object[].class)
            .invoke(broken, new Object[] { "size", new Object[0] });
        if (!Integer.valueOf(0).equals(sizeResult)) {
            throw new AssertionError("a method beside the missing method did not remain callable");
        }
        if (!(Boolean) wrapperClass.getMethod("getAvailable").invoke(healthy)) {
            throw new AssertionError("a separate healthy wrapper lost its capability");
        }
        if (!Integer.valueOf(0).equals(
            wrapperClass.getMethod("call", String.class, Object[].class)
                .invoke(healthy, new Object[] { "size", new Object[0] })
        )) {
            throw new AssertionError("the healthy wrapper's method did not remain callable");
        }

        try {
            wrapperClass.getMethod("call", String.class, Object[].class)
                .invoke(broken, new Object[] { "apkrunMissingFrameworkMethod", new Object[0] });
            throw new AssertionError("calling the missing method succeeded");
        } catch (InvocationTargetException error) {
            if (!missingMethodClass.isInstance(error.getCause())) {
                throw new AssertionError("missing method did not fail with ServiceMethodMissing", error.getCause());
            }
        }
    }

    private Object requirement(Class<?> requirementClass, String name) throws Exception {
        Constructor<?> constructor = requirementClass.getConstructor(String.class, List.class);
        return constructor.newInstance(name, Collections.singletonList(Collections.emptyList()));
    }

    private Object wrapper(
        Class<?> wrapperClass,
        Class<?> function2Class,
        ClassLoader targetLoader,
        String name,
        List<Object> requirements
    ) throws Exception {
        InvocationHandler lookupHandler = (proxy, method, args) -> {
            if ("invoke".equals(method.getName())) {
                return new ArrayList<>();
            }
            if ("toString".equals(method.getName())) {
                return "SystemServicesInstrumentationLookup";
            }
            if ("hashCode".equals(method.getName())) {
                return System.identityHashCode(proxy);
            }
            if ("equals".equals(method.getName())) {
                return proxy == args[0];
            }
            return null;
        };
        Object lookup = Proxy.newProxyInstance(
            targetLoader,
            new Class<?>[] { function2Class },
            lookupHandler
        );
        return wrapperClass.getConstructor(String.class, String.class, List.class, function2Class)
            .newInstance(name, "java.util.List", requirements, lookup);
    }
}
