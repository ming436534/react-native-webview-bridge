package com.github.alinz.reactnativewebviewbridge;

import android.os.Build;
import android.view.ContextMenu;
import android.view.View;
import android.webkit.WebSettings;
import android.webkit.WebView;

import com.afollestad.materialdialogs.MaterialDialog;
import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.ReadableArray;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.common.MapBuilder;
import com.facebook.react.uimanager.ThemedReactContext;
import com.facebook.react.uimanager.annotations.ReactProp;
import com.facebook.react.uimanager.events.RCTEventEmitter;
import com.facebook.react.views.webview.ReactWebViewManager;

import java.util.Map;

import javax.annotation.Nullable;

public class WebViewBridgeManager extends ReactWebViewManager implements View.OnCreateContextMenuListener {
    private static final String REACT_CLASS = "RCTWebViewBridge";
    
    public static final int COMMAND_SEND_TO_BRIDGE = 101;
    public static final int COMMAND_RESET_SOURCE = 102;

    public ThemedReactContext ctx;
    
    @Override
    public String getName() {
        return REACT_CLASS;
    }
    
    @Override
    public
    @Nullable
    Map<String, Integer> getCommandsMap() {
        Map<String, Integer> commandsMap = super.getCommandsMap();
        
        commandsMap.put("sendToBridge", COMMAND_SEND_TO_BRIDGE);
        commandsMap.put("resetSource", COMMAND_RESET_SOURCE);
        
        return commandsMap;
    }
    
    @Override
    protected WebView createViewInstance(ThemedReactContext reactContext) {
        WebView root = super.createViewInstance(reactContext);
        ctx = reactContext;
        WebSettings webSettings = root.getSettings();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            webSettings.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
        }
        root.addJavascriptInterface(new JavascriptBridge(root), "WebViewBridge");
        root.setOnCreateContextMenuListener(this);
        return root;
    }
    
    @Override
    public void receiveCommand(WebView root, int commandId, @Nullable ReadableArray args) {
        super.receiveCommand(root, commandId, args);
        
        switch (commandId) {
            case COMMAND_SEND_TO_BRIDGE:
                sendToBridge(root, args.getString(0));
                break;
            case COMMAND_RESET_SOURCE:
                resetSource(root);
            default:
                //do nothing!!!!
        }
    }

    private void resetSource(WebView root) {
        String o = root.getOriginalUrl();
        root.loadUrl(o);
    }
    
    private void sendToBridge(WebView root, String message) {
        String script = "WebViewBridge.onMessage('" + message + "');";
        WebViewBridgeManager.evaluateJavascript(root, script);
    }
    
    static private void evaluateJavascript(WebView root, String javascript) {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.KITKAT) {
            root.evaluateJavascript(javascript, null);
        } else {
            root.loadUrl("javascript:" + javascript);
        }
    }
    
    @ReactProp(name = "allowFileAccessFromFileURLs")
    public void setAllowFileAccessFromFileURLs(WebView root, boolean allows) {
        root.getSettings().setAllowFileAccessFromFileURLs(allows);
    }
    
    @ReactProp(name = "allowUniversalAccessFromFileURLs")
    public void setAllowUniversalAccessFromFileURLs(WebView root, boolean allows) {
        root.getSettings().setAllowUniversalAccessFromFileURLs(allows);
    }

    @Override
    public void onCreateContextMenu(ContextMenu contextMenu, View view, ContextMenu.ContextMenuInfo contextMenuInfo) {
        WebView wv = (WebView)view;
        WebView.HitTestResult rs = wv.getHitTestResult();
        final String url = rs.getExtra();
        if (url == null) {
            return;
        }
        WritableMap event = Arguments.createMap();
        event.putString("url", url);
        ctx.getJSModule(RCTEventEmitter.class).receiveEvent(
            wv.getId(),
            "WVB_LONG_PRESS",
            event
        );
    }
    public Map getExportedCustomBubblingEventTypeConstants() {
        return MapBuilder.builder()
                .put(
                        "WVB_LONG_PRESS",
                        MapBuilder.of(
                                "phasedRegistrationNames",
                                MapBuilder.of("bubbled", "onLongPressSelect")))
                .build();
    }
}
