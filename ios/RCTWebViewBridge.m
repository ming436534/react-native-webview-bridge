/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * Copyright (c) 2015-present, Ali Najafizadeh (github.com/alinz)
 * All rights reserved
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */
#if __has_include(<React/RCTAutoInsetsProtocol.h>)
#import <React/RCTAutoInsetsProtocol.h>
#import <React/RCTConvert.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>
#else
#import "RCTAutoInsetsProtocol.h"
#import "RCTConvert.h"
#import "RCTEventDispatcher.h"
#import "RCTLog.h"
#import "RCTUtils.h"
#endif

#import <UIKit/UIKit.h>

#import "RCTWebViewBridge.h"
#import "UIView+React.h"

#import <React/UIView+React.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>

//This is a very elegent way of defining multiline string in objective-c.
//source: http://stackoverflow.com/a/23387659/828487
#define NSStringMultiline(...) [[NSString alloc] initWithCString:#__VA_ARGS__ encoding:NSUTF8StringEncoding]

//we don'e need this one since it has been defined in RCTWebView.m
//NSString *const RCTJSNavigationScheme = @"react-js-navigation";
NSString *const RCTWebViewBridgeSchema = @"wvb";

// runtime trick to remove UIWebview keyboard default toolbar
// see: http://stackoverflow.com/questions/19033292/ios-7-uiwebview-keyboard-issue/19042279#19042279
@interface _SwizzleHelper : NSObject @end
@implementation _SwizzleHelper
-(id)inputAccessoryView
{
  return nil;
}
@end

@interface _LeakAvoider : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id delegate;
@end

@implementation _LeakAvoider
-(id)init:(id)delegate {
  self = [super init];
  self.delegate = delegate;
  return self;
}
-(void) userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
  if (self.delegate) {
    [self.delegate userContentController:userContentController didReceiveScriptMessage:message];
  }
}
@end

@interface RCTWebViewBridge () <WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, RCTAutoInsetsProtocol>

@property (nonatomic, copy) RCTDirectEventBlock onLoadingStart;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingFinish;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingError;
@property (nonatomic, copy) RCTDirectEventBlock onShouldStartLoadWithRequest;
@property (nonatomic, copy) RCTDirectEventBlock onBridgeMessage;
@property (nonatomic, copy) RCTDirectEventBlock onAlert;
@property (nonatomic, copy) RCTDirectEventBlock onConfirmDialog;
@property (nonatomic, copy) void (^alertCompletionHandler)();
@property (nonatomic, copy) void (^confirmCompletionHandler)(BOOL);
@property (assign) BOOL sendCookies;
@property (assign) BOOL useWKCookieStore;

@end

@implementation RCTWebViewBridge
{
  WKWebView *_webView;
  NSString *_injectedJavaScript;
  NSString *_userScript;
  WKUserContentController *_controller;
  BOOL loadEnded;
}

//- (instancetype)initWithFrame:(CGRect)frame
//{
//  if ((self = [super initWithFrame:frame])) {
//    super.backgroundColor = [UIColor clearColor];
//    _automaticallyAdjustContentInsets = YES;
//    _contentInset = UIEdgeInsetsZero;
//    [self setupWebview];
//    [self addSubview:_webView];
//    _shouldCache = NO;
//  }
//  return self;
//}
- (instancetype)initWithFrame:(CGRect)frame
{
  return self = [super initWithFrame:frame];
}
- (instancetype)initWithProcessPool:(WKProcessPool *)processPool
{
  if(self = [self initWithFrame:CGRectZero]) {
    super.backgroundColor = [UIColor clearColor];
    _automaticallyAdjustContentInsets = YES;
    _contentInset = UIEdgeInsetsZero;
    [self setupWebview:(WKProcessPool *)processPool];
    [self addSubview:_webView];
    _shouldCache = NO;
    loadEnded = true;
  }
  return self;
}



RCT_NOT_IMPLEMENTED(- (instancetype)initWithCoder:(NSCoder *)aDecoder)

- (void)loadRequest:(NSURLRequest *)request {
  if (request.URL && _sendCookies) {
    NSDictionary *cookies = [NSHTTPCookie requestHeaderFieldsWithCookies:[[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:request.URL]];
    if ([cookies objectForKey:@"Cookie"]) {
      NSMutableURLRequest *mutableRequest = request.mutableCopy;
      [mutableRequest addValue:cookies[@"Cookie"] forHTTPHeaderField:@"Cookie"];
      request = mutableRequest;
    }
  }
  if ([request.HTTPMethod isEqualToString:@"POST"] && request.HTTPBody.length > 0) {
    NSString* postData = [NSString stringWithUTF8String:[request.HTTPBody bytes]];
    NSString* js = NSStringMultiline(
     var params = "%@";
     var method = "post";
     var form = document.createElement("form");
     form.setAttribute("method", method);
     form.setAttribute("action", "%@");
     var keyValue = params.split("&");
     for (var i = 0; i < keyValue.length; i++) {
       var keyValueArray = keyValue[i].split("=");
       var hiddenField = document.createElement("input");
       hiddenField.setAttribute("type", "hidden");
       hiddenField.setAttribute("name", keyValueArray[0] || "");
       hiddenField.setAttribute("value", keyValueArray[1]);
       form.appendChild(hiddenField);
     }
     document.body.appendChild(form);
     form.submit();
    );
    NSString *jscript = [NSString stringWithFormat:js, postData, request.URL.absoluteString];
    [_webView evaluateJavaScript:jscript completionHandler:^(id object, NSError * _Nullable error) {
      NSLog(@"%@", error);
    }];
  } else {
    [_webView loadRequest:request];
  }
}

- (void)goForward
{
  [_webView goForward];
}

- (void)goBack
{
  [_webView goBack];
}

- (void)reload
{
  [_webView reload];
}

- (void)stopLoading
{
    [_webView stopLoading];
}

- (void)sendToBridge:(NSString *)message
{
  //we are warpping the send message in a function to make sure that if
  //WebView is not injected, we don't crash the app.
  NSString *format = NSStringMultiline(
    (function(){
      if (WebViewBridge && WebViewBridge.__push__) {
        WebViewBridge.__push__('%@');
      }
    }());
  );

  NSString *command = [NSString stringWithFormat: format, message];
  [_webView evaluateJavaScript:command completionHandler:^(id result, NSError * _Nullable error) {
    if (error) {
        NSLog(@"WKWebview sendToBridge evaluateJavaScript Error: %@", error);
    }
  }];
}

- (NSURL *)URL
{
  return _webView.URL;
}

- (void)setSource:(NSDictionary *)source
{
  if (![_source isEqualToDictionary:source]) {
    _source = [source copy];
    _sendCookies = [source[@"sendCookies"] boolValue];
    _useWKCookieStore = [source[@"useWKCookieStore"] boolValue];
    
    if (_useWKCookieStore) {
      [self copyCookies:^{
        [self setSourceToWebView:source];
      }];
    } else {
      [self setSourceToWebView:source];
    }
  }
}

- (void)setSourceToWebView:(NSDictionary *)source {
  // Check for a static html source first
  NSString *html = [RCTConvert NSString:source[@"html"]];
  if (html) {
    NSURL *baseURL = [RCTConvert NSURL:source[@"baseUrl"]];
    [_webView loadHTMLString:html baseURL:baseURL];
    return;
  }
  
  NSURLRequest *request = [RCTConvert NSURLRequest:source];
  NSMutableURLRequest *mutableRequest = [request mutableCopy];
  if (_shouldCache) mutableRequest.cachePolicy = NSURLRequestReturnCacheDataElseLoad;
  // Because of the way React works, as pages redirect, we actually end up
  // passing the redirect urls back here, so we ignore them if trying to load
  // the same url. We'll expose a call to 'reload' to allow a user to load
  // the existing page.
  if ([request.URL isEqual:_webView.URL]) {
    return;
  }
  if (!request.URL) {
    // Clear the webview
    [_webView loadHTMLString:@"" baseURL:nil];
    return;
  }
  [self loadRequest:mutableRequest];
}

-(void)setUserScript:(NSString *)userScript {
  _userScript = userScript;
  WKUserScript* generated = [[WKUserScript alloc] initWithSource:[self webViewBridgeScript] injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:true];
  [_controller addUserScript:generated];
}

- (void)resetSource
{
    [self loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]]];
    // Check for a static html source first
    NSString *html = [RCTConvert NSString:_source[@"html"]];
    if (html) {
        NSURL *baseURL = [RCTConvert NSURL:_source[@"baseUrl"]];
        [_webView loadHTMLString:html baseURL:baseURL];
        return;
    }
    
    NSURLRequest *request = [RCTConvert NSURLRequest:_source];
    NSMutableURLRequest *mutableRequest = [request mutableCopy];
    if (_shouldCache) mutableRequest.cachePolicy = NSURLRequestReturnCacheDataElseLoad;
    
    // Because of the way React works, as pages redirect, we actually end up
    // passing the redirect urls back here, so we ignore them if trying to load
    // the same url. We'll expose a call to 'reload' to allow a user to load
    // the existing page.
    // if ([request.URL isEqual:_webView.request.URL]) {
    //   return;
    // }
    if (!request.URL) {
        // Clear the webview
        [_webView loadHTMLString:@"" baseURL:nil];
        return;
    }
    [self loadRequest:mutableRequest];
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  _webView.frame = self.bounds;
}

- (void)setContentInset:(UIEdgeInsets)contentInset
{
  _contentInset = contentInset;
  [RCTView autoAdjustInsetsForView:self
                    withScrollView:_webView.scrollView
                      updateOffset:NO];
}

- (void)setBackgroundColor:(UIColor *)backgroundColor
{
  CGFloat alpha = CGColorGetAlpha(backgroundColor.CGColor);
  self.opaque = _webView.opaque = (alpha == 1.0);
  _webView.backgroundColor = backgroundColor;
}

- (UIColor *)backgroundColor
{
  return _webView.backgroundColor;
}

- (NSMutableDictionary<NSString *, id> *)baseEvent
{
  NSMutableDictionary<NSString *, id> *event = [[NSMutableDictionary alloc] initWithDictionary:@{
    @"url": _webView.URL.absoluteString ?: @"",
    @"loading" : @(_webView.loading),
    @"title": _webView.title,
    @"canGoBack": @(_webView.canGoBack),
    @"canGoForward" : @(_webView.canGoForward),
  }];

  return event;
}

- (NSMutableDictionary<NSString *, id> *)alertEvent:(NSString*) message
{
  NSMutableDictionary<NSString *, id> *event = [[NSMutableDictionary alloc] initWithDictionary:@{
   @"message": message,
   }];
  return event;
}
- (void)refreshContentInset
{
  [RCTView autoAdjustInsetsForView:self
                    withScrollView:_webView.scrollView
                      updateOffset:YES];
}

-(void)setHideKeyboardAccessoryView:(BOOL)hideKeyboardAccessoryView
{
  if (!hideKeyboardAccessoryView) {
    return;
  }

  UIView* subview;
  for (UIView* view in _webView.scrollView.subviews) {
    if([[view.class description] hasPrefix:@"UIWeb"])
      subview = view;
  }

  if(subview == nil) return;

  NSString* name = [NSString stringWithFormat:@"%@_SwizzleHelper", subview.class.superclass];
  Class newClass = NSClassFromString(name);

  if(newClass == nil)
  {
    newClass = objc_allocateClassPair(subview.class, [name cStringUsingEncoding:NSASCIIStringEncoding], 0);
    if(!newClass) return;

    Method method = class_getInstanceMethod([_SwizzleHelper class], @selector(inputAccessoryView));
      class_addMethod(newClass, @selector(inputAccessoryView), method_getImplementation(method), method_getTypeEncoding(method));

    objc_registerClassPair(newClass);
  }

  object_setClass(subview, newClass);
}

#pragma mark - WebKit WebView Setup and JS Handler

-(void)setupWebview:(WKProcessPool *)processPool {
  WKWebViewConfiguration *theConfiguration = [[WKWebViewConfiguration alloc] init];
  theConfiguration.processPool = processPool;
  WKUserContentController *controller = [[WKUserContentController alloc] init];
  _controller = controller;
  [controller addScriptMessageHandler:[[_LeakAvoider alloc] init:self] name:@"observe"];
  WKUserScript* userScript = [[WKUserScript alloc] initWithSource:[self webViewBridgeScript] injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:true];
  [controller addUserScript:userScript];
  [theConfiguration setUserContentController:controller];
  theConfiguration.allowsInlineMediaPlayback = NO;
  
  _webView = [[WKWebView alloc] initWithFrame:self.bounds configuration:theConfiguration];
  _webView.UIDelegate = self;
  _webView.navigationDelegate = self;
  
  [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];
}

-(void)dealloc {
  [_webView stopLoading];
  [_controller removeAllUserScripts];
  [_controller removeScriptMessageHandlerForName:@"observe"];
    if (_alertCompletionHandler != NULL) {
        _alertCompletionHandler();
        _alertCompletionHandler = NULL;
    }
    if (_confirmCompletionHandler != NULL) {
        _confirmCompletionHandler(false);
        _confirmCompletionHandler = NULL;
    }
  _controller = NULL;
}

-(void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message{
  if ([message.body containsString:@"FORCE_TRIGGER_LOAD_END"]) {
    [self loadFinish];
    return;
  }
  if ([message.body rangeOfString:RCTWebViewBridgeSchema].location == NSNotFound) {
    NSMutableDictionary<NSString *, id> *onBridgeMessageEvent = [[NSMutableDictionary alloc] initWithDictionary:@{
      @"messages": [self stringArrayJsonToArray: message.body]
    }];

    _onBridgeMessage(onBridgeMessageEvent);

    return;
  }

  [_webView evaluateJavaScript:@"WebViewBridge.__fetch__()" completionHandler:^(id result, NSError * _Nullable error) {
    if (!error) {
      NSMutableDictionary<NSString *, id> *onBridgeMessageEvent = [[NSMutableDictionary alloc] initWithDictionary:@{
        @"messages": [self stringArrayJsonToArray: result]
      }];

      _onBridgeMessage(onBridgeMessageEvent);
    }
  }];
}

- (void) persistingCookies:(RCTPromiseResolveBlock)resolve {
  if (@available(ios 11,*)) {
    if (_persistCookies != nil && _persistCookies.count > 0) {
      NSArray* persistCookies = [_persistCookies copy];
      dispatch_async(dispatch_get_main_queue(), ^(){
        WKHTTPCookieStore *cookieStore = [[WKWebsiteDataStore defaultDataStore] httpCookieStore];
        [cookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *allCookies) {
          for (NSHTTPCookie* cookie in allCookies) {
            for (NSDictionary* pc in persistCookies) {
              NSString* name = pc[@"name"];
              NSString* domain = pc[@"domain"];
              BOOL shouldPersist = false;
              if (name == nil) {
                shouldPersist = [cookie.domain containsString:domain];
              } else {
                shouldPersist = [cookie.domain containsString:domain] && [name isEqualToString:cookie.name];
              }
              if (shouldPersist) {
                NSMutableDictionary *cookieProperties = [NSMutableDictionary dictionary];
                [cookieProperties setObject:cookie.name forKey:NSHTTPCookieName];
                [cookieProperties setObject:cookie.value forKey:NSHTTPCookieValue];
                [cookieProperties setObject:cookie.domain forKey:NSHTTPCookieDomain];
                [cookieProperties setObject:cookie.path forKey:NSHTTPCookiePath];
                if (cookie.version > 0) {
                  NSString* cookieVersion = [NSString stringWithFormat:@"%ld", cookie.version];
                  [cookieProperties setObject:cookieVersion forKey:NSHTTPCookieVersion];
                }
                if (cookie.secure) {
                  [cookieProperties setObject:[NSNumber numberWithBool:true] forKey:NSHTTPCookieSecure];
                }
                if (cookie.expiresDate != nil) {
                  [cookieProperties setObject:cookie.expiresDate forKey:NSHTTPCookieExpires];
                } else {
                  [cookieProperties setObject:[NSDate dateWithTimeIntervalSinceNow:3 * 60 * 60] forKey:NSHTTPCookieExpires];
                }
                NSHTTPCookie* newCookie = [NSHTTPCookie cookieWithProperties:cookieProperties];
                [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookie:newCookie];
              }
            }
          }
          resolve(nil);
        }];
      });
    }
  } else {
    resolve(nil);
  }
}

#pragma mark - WebKit WebView Delegate methods

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation{
}

-(void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler{
  NSMutableDictionary<NSString *, id> *event = [self baseEvent];
  [event addEntriesFromDictionary: @{
    @"navigationType": @(navigationAction.navigationType)
  }];
  event[@"url"] = (navigationAction.request.URL).absoluteString;
  if (_onShouldStartLoadWithRequest) {
    if (![self.delegate webView:self shouldStartLoadForRequest:event withCallback:_onShouldStartLoadWithRequest]) {
      decisionHandler(WKNavigationActionPolicyCancel);
    }else{
      decisionHandler(WKNavigationActionPolicyAllow);
      if (_onLoadingStart && [navigationAction.request.URL isEqual:navigationAction.request.mainDocumentURL]) {
        loadEnded = false;
        _onLoadingStart(event);
      }
    }
    return;
  }
  NSURLRequest *request = navigationAction.request;
  BOOL isTopFrame = [request.URL isEqual:request.mainDocumentURL];
  if (_onLoadingStart && isTopFrame) {
    loadEnded = false;
    _onLoadingStart(event);
  }
  decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
  if (_sendCookies) {
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)navigationResponse.response;
    NSArray *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:[response allHeaderFields] forURL:response.URL];
    for (NSHTTPCookie *cookie in cookies) {
      [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookie:cookie];
    }
  }
  decisionHandler(WKNavigationResponsePolicyAllow);
}

-(void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error{
  if (_onLoadingError) {
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
      // NSURLErrorCancelled is reported when a page has a redirect OR if you load
      // a new URL in the WebView before the previous one came back. We can just
      // ignore these since they aren't real errors.
      // http://stackoverflow.com/questions/1024748/how-do-i-fix-nsurlerrordomain-error-999-in-iphone-3-0-os
      return;
    }

    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    [event addEntriesFromDictionary:@{
      @"domain": error.domain,
      @"code": @(error.code),
      @"description": error.localizedDescription,
    }];
    _onLoadingError(event);
  }
}

-(void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation{
  if (!loadEnded) {
    [self loadFinish];
  }
}

-(void) loadFinish {
  loadEnded = true;
  if (_injectedJavaScript != nil) {
    [_webView evaluateJavaScript:_injectedJavaScript completionHandler:^(id result, NSError * _Nullable error) {
      NSString *jsEvaluationValue = (NSString *) result;
      NSMutableDictionary<NSString *, id> *event = [self baseEvent];
      event[@"jsEvaluationValue"] = jsEvaluationValue;
      if (_onLoadingFinish) {
        _onLoadingFinish(event);
      }
    }];
  } else if (_onLoadingFinish) {
    _onLoadingFinish([self baseEvent]);
  }
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures
{
  if (!navigationAction.targetFrame.isMainFrame) {
    [self loadRequest:navigationAction.request];
  }

  return nil;
}

#pragma mark - WebviewBridge helpers

- (NSArray*)stringArrayJsonToArray:(NSString *)message
{
  return [NSJSONSerialization JSONObjectWithData:[message dataUsingEncoding:NSUTF8StringEncoding]
                                         options:NSJSONReadingAllowFragments
                                           error:nil];
}

-(void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler{
  if (_handleAlertNative) {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:message message:nil preferredStyle:UIAlertControllerStyleAlert];
    
    [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Close", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
      completionHandler();
    }]];
    UIViewController *presentingController = RCTPresentedViewController();
    [presentingController presentViewController:alertController animated:YES completion:nil];
  } else {
    _alertCompletionHandler = completionHandler;
    _onAlert([self alertEvent:message]);
  }
}
- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler{
  if (_handleAlertNative) {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:message message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
      completionHandler(YES);
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
      completionHandler(NO);
    }]];
    UIViewController *presentingController = RCTPresentedViewController();
    [presentingController presentViewController:alertController animated:YES completion:nil];
  } else {
    _confirmCompletionHandler = completionHandler;
    _onConfirmDialog([self alertEvent:message]);
  }
  
}

- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString *))completionHandler {
  
  UIAlertController *alertController = [UIAlertController alertControllerWithTitle:prompt message:nil preferredStyle:UIAlertControllerStyleAlert];
  [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
    textField.text = defaultText;
  }];
  
  [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    NSString *input = ((UITextField *)alertController.textFields.firstObject).text;
    completionHandler(input);
  }]];
  
  [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
    completionHandler(nil);
  }]];
  UIViewController *presentingController = RCTPresentedViewController();
  [presentingController presentViewController:alertController animated:YES completion:nil];
}

//since there is no easy way to load the static lib resource in ios,
//we are loading the script from this method.
- (NSString *)webViewBridgeScript {
  // NSBundle *bundle = [NSBundle mainBundle];
  // NSString *webViewBridgeScriptFile = [bundle pathForResource:@"webviewbridge"
  //                                                      ofType:@"js"];
  // NSString *webViewBridgeScriptContent = [NSString stringWithContentsOfFile:webViewBridgeScriptFile
  //                                                                  encoding:NSUTF8StringEncoding
  //                                                                     error:nil];

  NSString* js = NSStringMultiline(
     window.bakJsonStringify = JSON.stringify;
     window.bakJsonParse = JSON.parse;
     function userScriptKK() {
       ___REPLACE_WITH_USER_SCRIPT___
     }
    (function (window) {
      //Make sure that if WebViewBridge already in scope we don't override it.
      if (window.WebViewBridge) {
        return;
      }
      var RNWBSchema = 'wvb';
      var sendQueue = [];
      var receiveQueue = [];
      var doc = window.document;
      var customEvent = doc.createEvent('Event');

      function wkWebViewBridgeAvailable() {
        return (
          window.webkit &&
          window.webkit.messageHandlers &&
          window.webkit.messageHandlers.observe &&
          window.webkit.messageHandlers.observe.postMessage
        );
      }

      function wkWebViewSend(event) {
        if (!wkWebViewBridgeAvailable()) {
          return;
        }
        try {
          window.webkit.messageHandlers.observe.postMessage(event);
        } catch (e) {
          console.error('wkWebViewSend error', e.message);
          if (window.WebViewBridge.onError) {
            window.WebViewBridge.onError(e);
          }
        }
      }

      function callFunc(func, message) {
        if ('function' === typeof func) {
          func(message);
        }
      }

      function signalNative() {
        if (wkWebViewBridgeAvailable()) {
          var event = window.WebViewBridge.__fetch__();
          wkWebViewSend(event);
        } else { // iOS UIWebview
          window.location = RNWBSchema + '://message' + new Date().getTime();
        }
      }

      //I made the private function ugly signiture so user doesn't called them accidently.
      //if you do, then I have nothing to say. :(
      var WebViewBridge = {
        //this function will be called by native side to push a new message
        //to webview.
        __push__: function (message) {
          receiveQueue.push(message);
          //reason I need this setTmeout is to return this function as fast as
          //possible to release the native side thread.
          setTimeout(function () {
            var message = receiveQueue.pop();
            callFunc(WebViewBridge.onMessage, message);
          }, 15); //this magic number is just a random small value. I don't like 0.
        },
        __fetch__: function () {
          //since our sendQueue array only contains string, and our connection to native
          //can only accept string, we need to convert array of strings into single string.
          var messages = window.bakJsonStringify(sendQueue);

          //we make sure that sendQueue is resets
          sendQueue = [];

          //return the messages back to native side.
          return messages;
        },
        //make sure message is string. because only string can be sent to native,
        //if you don't pass it as string, onError function will be called.
        send: function (message) {
          if ('string' !== typeof message) {
            callFunc(WebViewBridge.onError, "message is type '" + typeof message + "', and it needs to be string");
            return;
          }

          //we queue the messages to make sure that native can collects all of them in one shot.
          sendQueue.push(message);
          //signal the objective-c that there is a message in the queue
          signalNative();
        },
        onMessage: null,
        onError: null
      };

      window.WebViewBridge = WebViewBridge;
      //dispatch event
      customEvent.initEvent('WebViewBridge', true, true);
      doc.dispatchEvent(customEvent);
    })(this);
    userScriptKK();
  );
  NSString* customUserScript = _userScript ? _userScript : @"";
  NSLog(@"%@", [js stringByReplacingOccurrencesOfString:@"___REPLACE_WITH_USER_SCRIPT___" withString:customUserScript]);
  return [js stringByReplacingOccurrencesOfString:@"___REPLACE_WITH_USER_SCRIPT___" withString:customUserScript];
}

-(void) resolveAlert {
  if (_alertCompletionHandler) {
    _alertCompletionHandler();
    _alertCompletionHandler = NULL;
  }
}
-(void)setAllowsLinkPreview:(BOOL)allowsLinkPreview
{
  if ([_webView respondsToSelector:@selector(allowsLinkPreview)]) {
    _webView.allowsLinkPreview = allowsLinkPreview;
  }
}
-(void) resolveConfirm:(BOOL)result {
  if (_confirmCompletionHandler) {
    _confirmCompletionHandler(result);
    _confirmCompletionHandler = NULL;
  }
}

- (NSString *) cookieDescription:(NSHTTPCookie *)cookie {
  
  NSMutableString *cDesc = [[NSMutableString alloc] init];
  [cDesc appendFormat:@"%@=%@;",
   [[cookie name] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding],
   [[cookie value] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
  if ([cookie.domain length] > 0)
    [cDesc appendFormat:@"domain=%@;", [cookie domain]];
  if ([cookie.path length] > 0)
    [cDesc appendFormat:@"path=%@;", [cookie path]];
  if (cookie.expiresDate != nil)
    [cDesc appendFormat:@"expiresDate=%@;", [cookie expiresDate]];
  if (cookie.HTTPOnly == YES)
    [cDesc appendString:@"HttpOnly;"];
  if (cookie.secure == YES)
    [cDesc appendString:@"Secure;"];
  
  
  return cDesc;
}

- (void) copyCookies:(void (^)(void))completionHandler {
  if (@available(ios 11,*)) {
    
    // The webView websiteDataStore only gets initialized, when needed. Setting cookies on the dataStore's
    // httpCookieStore doesn't seem to initialize it. That's why fetchDataRecordsOfTypes is called.
    // All the cookies of the sharedHttpCookieStorage, which is used in react-native-cookie,
    // are copied to the webSiteDataStore's httpCookieStore.
    // https://bugs.webkit.org/show_bug.cgi?id=185483
    NSHTTPCookieStorage* storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray* array = [storage cookies];
    [_webView.configuration.websiteDataStore fetchDataRecordsOfTypes:[NSSet<NSString *> setWithObject:WKWebsiteDataTypeCookies] completionHandler:^(NSArray<WKWebsiteDataRecord *> *records) {
      for (NSHTTPCookie* cookie in array) {
        [_webView.configuration.websiteDataStore.httpCookieStore setCookie:cookie completionHandler:nil];
      }
      completionHandler();
    }];
  } else {
    // Create WKUserScript for each cookie
    // Cookies are injected with Javascript AtDocumentStart
    NSHTTPCookieStorage* storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray* array = [storage cookies];
    for (NSHTTPCookie* cookie in array){
      NSString* cookieSource = [NSString stringWithFormat:@"document.cookie = '%@'", [self cookieDescription:cookie]];
      WKUserScript* cookieScript = [[WKUserScript alloc]
                                    initWithSource:cookieSource
                                    injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
      [_webView.configuration.userContentController addUserScript:cookieScript];
    }
    completionHandler();
  }
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
  RCTLogWarn(@"Webview Process Terminated");
}

@end
