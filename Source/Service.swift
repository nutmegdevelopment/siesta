//
//  Service.swift
//  Siesta
//
//  Created by Paul on 2015/6/15.
//  Copyright © 2015 Bust Out Solutions. All rights reserved.
//

import Foundation

/**
A set of logically connected RESTful resources, grouped under a base URL.

You will typically create a separate subclass of `Service` for each REST API you use.
*/
@objc(BOSService)
public class Service: NSObject
    {
    /// The root URL of the API.
    public let baseURL: NSURL?
    
    internal let networkingProvider: NetworkingProvider
    private var resourceCache = WeakCache<String,Resource>()
    
    /**
      Creates a new service for the given API.
      
      - Parameter: base The base URL of the API.
      - Parameter: useDefaultTransformers If true, include handling for JSON and text. If false, leave all responses as
          `NSData` (unless you add your own `ResponseTransformer` using `configure(...)`).
      - Parameter: networkingProvider A provider to use for networking. The default is Alamofire with its default
          configuration. You can pass an `AlamofireProvider` created with a custom configuration,
          or provide your own networking implementation.
    */
    public init(
            base: String,
            useDefaultTransformers: Bool = true,
            networkingProvider: NetworkingProvider = AlamofireProvider())
        {
        self.baseURL = NSURL(string: base.URLString)?.alterPath
            {
            path in
            !path.hasSuffix("/")
                ? path + "/"
                : path
            }
        self.networkingProvider = networkingProvider
        
        super.init()
        
        if useDefaultTransformers
            {
            configure
                {
                $0.config.responseTransformers.add(JsonTransformer(), contentTypes: ["*/json", "*/*+json"])
                $0.config.responseTransformers.add(TextTransformer(), contentTypes: ["text/*"])
                }
            }
        }
    
    /**
      Returns the unique resource with the given URL.
     
      This method will _always_ return the same instance of `Resource` for the same URL within
      the context of a `Service` as long as anyone retains a reference to that resource.
      Unreferenced resources remain in memory (with their cached data) until a low memory event
      occurs, at which point they are summarily evicted.
    */
    @objc(resourceWithURL:)
    public final func resource(url: NSURL?) -> Resource
        {
        let key = url?.absoluteString ?? ""  // TODO: handle invalid URLs
        return resourceCache.get(key)
            {
            Resource(service: self, url: url)
            }
        }
    
    /// Return the unique resource with the given path relative to `baseURL`.
    @objc(resourceWithPath:)
    public final func resource(path: String) -> Resource
        {
        return resource(baseURL?.URLByAppendingPathComponent(path.stripPrefix("/")))
        }
    
    // MARK: Resource Configuration
    
    internal var configVersion: UInt64 = 0
    private var configurationEntries: [ConfigurationEntry] = []
        {
        didSet { invalidateConfiguration() }
        }
    
    /**
      Adds global configuration to apply to all resources in this service. For example:
      
          service.configure { $0.config.headers["Foo"] = "bar" }
      
      The `configurer` block is evaluated every time a matching resource asks for its configuration.
      
      The optional `description` is used for logging purposes only.
      
      Matching configuration closures apply in the order they were added, whether global or not. That means that you
      will usually want to apply your global configuration first, then your resource-specific configuration.
      
      - SeeAlso: `configure(_:configurer:)`
      - SeeAlso: `invalidateConfiguration()`
    */
    public final func configure(
            description description: String = "global",
            configurer: Configuration.Builder -> Void)
        {
        configure(
            { _ in true },
            description: description,
            configurer: configurer)
        }
    
    /**
      Adds configuration for one resource’s URL. You add configuration this way instead of setting properties directly
      on the resource because `Resource` instances may be discarded and recreated when they are not in use.
    */
    public final func configure(
            resource: Resource,
            description: String? = nil,
            configurer: Configuration.Builder -> Void)
        {
        let resourceURL = resource.url!
        configure(
            { $0 == resourceURL },
            description: description ?? resourceURL.absoluteString,
            configurer: configurer)
        }
    
    /**
      Applies additional configuration to resources matching the given pattern.
      
      For example:
      
          configure("/items")    { $0.config.expirationTime = 5 }
          configure("/items/​*")  { $0.config.headers["Funkiness"] = "Very" }
          configure("/admin/​**") { $0.config.headers["Auth-token"] = token }
    
      The `urlPattern` is interpreted relative to the service’s base URL unless it begins with a protocol (e.g. `http:`).
      If it is relative, the leading slash is optional.
      
      The pattern supports two wildcards:
      
      - `*` matches zero or more characters within a path segment, and
      - `**` matches zero or more characters across path segments, with the special case that `/**/` matches `/`.
      
      Examples:
      
      - `/foo/*/bar` matches `/foo/1/bar` and  `/foo/123/bar`.
      - `/foo/**/bar` matches `/foo/bar`, `/foo/123/bar`, and `/foo/1/2/3/bar`.
      - `/foo*/bar` matches `/foo/bar` and `/food/bar`.
    
      The pattern ignores the resource’s query string.
      
      If you need more fine-grained URL matching, use the predicate flavor of this method.
      
      - SeeAlso: `configure(configurer:)`
      - SeeAlso: `configure(_:predicate:configurer:)`
      - SeeAlso: `invalidateConfiguration()`
    */
    public final func configure(
            urlPattern: String,
            description: String? = nil,
            configurer: Configuration.Builder -> Void)
        {
        let prefix = urlPattern.containsRegex("^[a-z]+:")
            ? ""                       // If pattern has a protocol, interpret as absolute URL
            : baseURL!.absoluteString  // Pattern is relative to API base
        let resolvedPattern = prefix + urlPattern.stripPrefix("/")
        let pattern = NSRegularExpression.compile(
            NSRegularExpression.escapedPatternForString(resolvedPattern)
                .replaceString("\\*\\*\\/", "([^:?]*/|)")
                .replaceString("\\*\\*",    "[^:?]*")
                .replaceString("\\*",       "[^/:?]*")
                + "($|\\?)")
        
        debugLog(.Configuration, ["URL pattern", urlPattern, "compiles to regex", pattern.pattern])
        
        configure(
            { pattern.matches($0.absoluteString) },
            description: description ?? urlPattern,
            configurer: configurer)
        }
    
    /**
      Accepts an arbitrary URL matching predicate if the wildcards in the `urlPattern` flavor of `configure()`
      aren’t robust enough.
    */
    public final func configure(
            urlMatcher: NSURL -> Bool,
            description: String? = nil,
            configurer: Configuration.Builder -> Void)
        {
        let entry = ConfigurationEntry(
            description: description ?? "custom",
            urlMatcher: urlMatcher,
            configurer: configurer)
        configurationEntries.append(entry)
        debugLog(.Configuration, ["Added", entry, "config"])
        }
    
    /**
      Signals that all resources need to recompute their configuration next time they need it.
      
      Because the `configure(...)` methods accept an arbitrary closure, it is possible that the results of
      that closure could change over time. However, resources cache their configuration after it is computed. Therefore,
      if you do anything that would change the result of a configuration closure, you must call
      `invalidateConfiguration()` in order for the changes to take effect.
      
      _《insert your functional programming purist rant here if you so desire》_

      Note that you do _not_ need to call this method after calling any of the `configure(...)` methods.
      You only need to call it if one of the previously passed closures will now behave differently.
    
      For example, to make a header track the value of a modifiable property:

          var flavor: String {
            didSet { invalidateConfiguration() }
          }

          init() {
            super.init(base: "https://api.github.com")
            configure​ {
              $0.config.headers["Flavor-of-the-month"] = self.flavor  // NB: use weak self if service isn’t a singleton
            }
          }
    
      Note that this method does _not_ immediately recompute all existing configurations. This is an inexpensive call.
      Configurations are computed lazily, and the (still relatively low) performance impact of recomputation is spread
      over subsequent resource interactions.
    */
    public final func invalidateConfiguration()
        {
        debugLog(.Configuration, ["Configurations need to be recomputed"])
        configVersion++
        }
    
    internal func configurationForResource(resource: Resource) -> Configuration
        {
        debugLog(.Configuration, ["Recomputing configuration for", resource])
        let builder = Configuration.Builder()
        for entry in configurationEntries
            where entry.urlMatcher(resource.url!)
            {
            debugLog(.Configuration, ["Applying", entry, "config to", resource])
            entry.configurer(builder)
            }
        return builder.config
        }
    
    private struct ConfigurationEntry: CustomStringConvertible
        {
        let description: String
        let urlMatcher: NSURL -> Bool
        let configurer: Configuration.Builder -> Void
        }
    
    // MARK: Wiping state
    
    /**
      Wipes the state of this service’s resources. Typically used to handle logout.
      
      Applies to resources matching the predicate, or all resources by default.
    */
    public final func wipeResources(predicate: Resource -> Bool =  { _ in true })
        {
        resourceCache.flushUnused()
        for resource in resourceCache.values
            {
            if predicate(resource)
                { resource.wipe() }
            }
        }
    }
