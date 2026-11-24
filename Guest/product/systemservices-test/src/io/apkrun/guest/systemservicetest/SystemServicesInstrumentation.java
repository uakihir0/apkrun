package io.apkrun.guest.systemservicetest;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.os.Bundle;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Runs the production Guest Agent SystemServices wrappers against the custom Android image. */
public final class SystemServicesInstrumentation extends Instrumentation {
    private static final String AGENT_PACKAGE = "io.apkrun.guest";
    private static final String SYSTEM_SERVICES = "io.apkrun.guest.runtime.SystemServices";
    private static final String WRAPPER = "io.apkrun.guest.runtime.SystemServiceWrapper";
    private static final String METHOD_REQUIREMENT = "io.apkrun.guest.runtime.MethodRequirement";

    @Override
    public void onStart() {
        Bundle results = new Bundle();
        int resultCode = Activity.RESULT_CANCELED;
        try {
            ClassLoader agentLoader = agentClassLoader();
            Object services = systemServices(agentLoader);
            List<?> wrappers = (List<?>) systemServicesClass(agentLoader)
                    .getMethod("getAll")
                    .invoke(services);
            List<String> missingMethods = new ArrayList<>();
            List<String> wrapperNames = verifyWrappers(wrappers, missingMethods);
            verifyMissingMethodIsolation(agentLoader);

            results.putString("wrappers", String.join(",", wrapperNames));
            results.putInt("wrapper_count", wrapperNames.size());
            results.putString("missing_methods", String.join(",", missingMethods));
            results.putString("missing_method_isolated", "true");
            results.putString("expected_capabilities", expectedCapabilities(services));
            resultCode = Activity.RESULT_OK;
        } catch (Throwable error) {
            Throwable cause = error.getCause() == null ? error : error.getCause();
            results.putString("failure", cause.getClass().getName() + ": " + cause.getMessage());
        } finally {
            finish(resultCode, results);
        }
    }

    private ClassLoader agentClassLoader() throws Exception {
        Context agentContext = getContext().createPackageContext(
                AGENT_PACKAGE, Context.CONTEXT_INCLUDE_CODE | Context.CONTEXT_IGNORE_SECURITY);
        return agentContext.getClassLoader();
    }

    private Object systemServices(ClassLoader agentLoader) throws Exception {
        return systemServicesClass(agentLoader).getField("INSTANCE").get(null);
    }

    private Class<?> systemServicesClass(ClassLoader agentLoader) throws ClassNotFoundException {
        return agentLoader.loadClass(SYSTEM_SERVICES);
    }

    private List<String> verifyWrappers(List<?> wrappers, List<String> missingMethods) throws Exception {
        if (wrappers.size() != 8) {
            throw new AssertionError("expected 8 service wrappers, found " + wrappers.size());
        }

        List<String> names = new ArrayList<>();
        Set<String> uniqueNames = new HashSet<>();
        for (Object wrapper : wrappers) {
            Class<?> type = wrapper.getClass();
            String serviceName = (String) type.getMethod("getServiceName").invoke(wrapper);
            boolean available = (Boolean) type.getMethod("getAvailable").invoke(wrapper);
            Object interfaceClass = type.getMethod("getInterfaceClass").invoke(wrapper);
            Object service = type.getMethod("getService").invoke(wrapper);

            List<?> missing = (List<?>) type.getMethod("getMissingMethods").invoke(wrapper);
            if (available) {
                if (interfaceClass == null || service == null || !missing.isEmpty()) {
                    throw new AssertionError(serviceName + " reported an inconsistent available wrapper");
                }
            } else if (missing.isEmpty()) {
                throw new AssertionError(serviceName + " is unavailable without a missing method");
            }
            for (Object method : missing) {
                missingMethods.add(serviceName + "." + method);
            }
            names.add(serviceName);
            uniqueNames.add(serviceName);
        }

        Set<String> required = new HashSet<>(Arrays.asList(
                "display", "window", "activity_task", "activity", "power", "input", "lock_settings"));
        if (!uniqueNames.containsAll(required)) {
            required.removeAll(uniqueNames);
            throw new AssertionError("missing service wrappers: " + required);
        }
        int activityTaskCount = Collections.frequency(names, "activity_task");
        int activityCount = Collections.frequency(names, "activity");
        if (activityTaskCount + activityCount != 3 || activityTaskCount < 1 || activityCount < 1) {
            throw new AssertionError("unexpected activity wrapper selection: " + names);
        }
        return names;
    }

    private String expectedCapabilities(Object services) throws Exception {
        Class<?> type = services.getClass();
        Object display = type.getMethod("getDisplay").invoke(services);
        Object window = type.getMethod("getWindow").invoke(services);
        Object activityTask = type.getMethod("getActivityTask").invoke(services);
        Object activity = type.getMethod("getActivity").invoke(services);
        Object input = type.getMethod("getInput").invoke(services);
        Object power = type.getMethod("getPower").invoke(services);

        List<String> expected = new ArrayList<>();
        boolean displayAvailable =
                supports(display, "getDisplayIds")
                && supports(display, "getDisplayInfo")
                && supports(display, "registerCallback")
                && supports(window, "setForcedDisplayDensityForUser")
                && supports(window, "setDisplayImePolicy");
        boolean launchAvailable =
                supports(activityTask, "getTasks")
                && supports(activityTask, "registerTaskStackListener")
                && supports(activityTask, "startActivityAsUser")
                && supports(activityTask, "moveRootTaskToDisplay")
                && supports(activityTask, "removeTask")
                && supports(activityTask, "setFocusedTask")
                && supports(activity, "forceStopPackage");
        boolean inputAvailable =
                supports(activityTask, "getTasks")
                && supports(activityTask, "setFocusedTask")
                && supports(input, "injectInputEvent");
        boolean systemAvailable = supports(power, "shutdown");

        if (displayAvailable) expected.add("display.v1");
        if (launchAvailable) expected.add("launch.v1");
        if (inputAvailable) expected.add("input.v1");
        if (systemAvailable) expected.add("system.v1");
        return String.join(",", expected);
    }

    private boolean supports(Object wrapper, String method) throws Exception {
        return (Boolean) wrapper.getClass()
                .getMethod("supports", String.class)
                .invoke(wrapper, method);
    }

    private void verifyMissingMethodIsolation(ClassLoader agentLoader) throws Exception {
        Class<?> requirementType = agentLoader.loadClass(METHOD_REQUIREMENT);
        Object existingMethod = requirementType
                .getConstructor(String.class, List.class)
                .newInstance("size", Collections.singletonList(Collections.emptyList()));
        Object missingMethod = requirementType
                .getConstructor(String.class, List.class)
                .newInstance("missingFixtureMethod", Collections.singletonList(Collections.emptyList()));

        Class<?> function2Type = agentLoader.loadClass("kotlin.jvm.functions.Function2");
        InvocationHandler lookupHandler = (proxy, method, arguments) ->
                method.getName().equals("invoke") ? new ArrayList<>() : null;
        Object lookup = Proxy.newProxyInstance(
                agentLoader, new Class<?>[] {function2Type}, lookupHandler);

        Class<?> wrapperType = agentLoader.loadClass(WRAPPER);
        Constructor<?> constructor = wrapperType.getConstructor(
                String.class, String.class, List.class, function2Type);
        Object fixture = constructor.newInstance(
                "instrumentation_fixture",
                "java.util.List",
                Arrays.asList(existingMethod, missingMethod),
                lookup);

        if ((Boolean) wrapperType.getMethod("getAvailable").invoke(fixture)) {
            throw new AssertionError("a wrapper with one missing method was reported as available");
        }
        if (!(Boolean) wrapperType.getMethod("supports", String.class).invoke(fixture, "size")) {
            throw new AssertionError("the resolved method was disabled with its missing sibling");
        }
        if ((Boolean) wrapperType
                .getMethod("supports", String.class)
                .invoke(fixture, "missingFixtureMethod")) {
            throw new AssertionError("the missing method was reported as supported");
        }
        Object result = wrapperType.getMethod("call", String.class, Object[].class)
                .invoke(fixture, "size", new Object[] {new Object[0]});
        if (!Integer.valueOf(0).equals(result)) {
            throw new AssertionError("the resolved method stopped working: " + result);
        }
        try {
            wrapperType.getMethod("call", String.class, Object[].class)
                    .invoke(fixture, "missingFixtureMethod", new Object[] {new Object[0]});
            throw new AssertionError("calling a missing method unexpectedly succeeded");
        } catch (java.lang.reflect.InvocationTargetException expected) {
            if (!"io.apkrun.guest.runtime.ServiceMethodMissing"
                    .equals(expected.getCause().getClass().getName())) {
                throw expected;
            }
        }
    }
}
