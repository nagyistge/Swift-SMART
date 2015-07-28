//
//  Server.swift
//  SMART-on-FHIR
//
//  Created by Pascal Pfiffner on 6/11/14.
//  Copyright (c) 2014 SMART Health IT. All rights reserved.
//

import Foundation


/**
    Representing the FHIR resource server a client connects to.
    
    This implementation holds on to an `Auth` instance to handle authentication. It is automatically instantiated with properties from the
    settings dictionary provided upon initalization of the Server instance OR from the server's Conformance statement.

    This implementation automatically downloads and parses the FHIR Conformance statement, which is used during various tasks, such as
    instantiating the `Auth` instance or validating/executing operations.

    This implementation manages its own NSURLSession, either with an optional delegate provided via `sessionDelegate` or simply the shared
    session. Subclasses can change this behavior by overriding `createDefaultSession` or any of the other request-related methods.
 */
public class Server: FHIRServer
{
	/// The service URL as a string, as specified during initalization to be used as `aud` parameter.
	final let aud: String
	
	/// The server's base URL.
	public final let baseURL: NSURL
	
	/// An optional name of the server; will be read from conformance statement unless manually assigned.
	public final var name: String?
	
	/// The authorization to use with the server.
	var auth: Auth?
	
	/// Settings to be applied to the Auth instance.
	var authSettings: OAuth2JSON? {
		didSet {
			didSetAuthSettings()
		}
	}
	
	/// The operations the server supports, as specified in the conformance statement.
	var operations: [String: OperationDefinition]?
	var conformanceOperations: [ConformanceRestOperation]?
	
	/// The active URL session.
	var session: NSURLSession?
	
	/// An optional NSURLSessionDelegate.
	public var sessionDelegate: NSURLSessionDelegate? {
		didSet {
			session = nil
			if let oauth = auth?.oauth {
				oauth.sessionDelegate = sessionDelegate
			}
		}
	}
	
	
	/**
	Main initializer. Makes sure the base URL ends with a "/" to facilitate URL generation later on.
	*/
	public init(baseURL base: NSURL, auth: OAuth2JSON? = nil) {
		aud = base.absoluteString ?? "http://localhost"
		if let baseStr = base.absoluteString where baseStr[advance(baseStr.endIndex, -1)] != "/" {
			baseURL = base.URLByAppendingPathComponent("/")
		}
		else {
			baseURL = base
		}
		authSettings = auth
		didSetAuthSettings()
	}
	
	public convenience init(base: String, auth: OAuth2JSON? = nil) {
		self.init(baseURL: NSURL(string: base)!, auth: auth)			// yes, this will crash on invalid URL
	}
	
	func didSetAuthSettings() {
		var authType: AuthType? = nil
		if let typ = authSettings?["authorize_type"] as? String {
			authType = AuthType(rawValue: typ)
		}
		if nil == authType || .None == authType! {
			if let ath = authSettings?["authorize_uri"] as? String {
				if let tok = authSettings?["token_uri"] as? String {
					authType = .CodeGrant
				}
				else {
					authType = .ImplicitGrant
				}
			}
		}
		if let type = authType {
			auth = Auth(type: type, server: self, settings: authSettings)
			logIfDebug("Initialized server auth of type “\(type.rawValue)”")
		}
	}
	
	
	// MARK: - Server Conformance
	
	/// The server's conformance statement. Must be implicitly fetched using `getConformance()`
	public var conformance: Conformance? {							// `public` to enable unit testing
		didSet {
			if nil == name && nil != conformance?.name {
				name = conformance!.name
			}
			
			// look at ConformanceRest entries for security and operation information
			if let rests = conformance?.rest {
				var best: ConformanceRest?
				for rest in rests {
					if nil == best {
						best = rest
					}
					else if "client" == rest.mode {
						best = rest
						break
					}
				}
				
				// use the "best" matching rest entry to extract the information we want
				if let rest = best {
					if let security = rest.security {
						auth = Auth.fromConformanceSecurity(security, server: self, settings: authSettings)
						logIfDebug("Initialized server auth of type “\(auth?.type.rawValue)”")
					}
					
					// if we have not yet initialized an Auth object we'll use one for "no auth"
					if nil == auth {
						auth = Auth(type: .None, server: self, settings: authSettings)
						logIfDebug("Server seems to be open, proceeding with none-type auth")
					}
					
					if let operations = rest.operation {
						conformanceOperations = operations
					}
				}
			}
		}
	}
	
	/**
	    Executes a `read` action against the server's "metadata" path, which should return a Conformance statement.
	
	    Is public to enable unit testing.
	 */
	public final func getConformance(callback: (error: NSError?) -> ()) {
		if nil != conformance {
			callback(error: nil)
			return
		}
		
		// not yet fetched, fetch it
		Conformance.readFrom("metadata", server: self) { resource, error in
			if let conf = resource as? Conformance {
				self.conformance = conf
				callback(error: nil)
			}
			else {
				callback(error: error ?? genSMARTError("Conformance.readFrom() did not return a Conformance instance but \(resource)"))
			}
		}
	}
	
	
	// MARK: - Authorization
	
	public func authClientCredentials() -> (id: String, secret: String?)? {
		if let clientId = auth?.oauth?.clientId where !clientId.isEmpty {
			return (id: clientId, secret: auth?.oauth?.clientSecret)
		}
		return nil
	}
	
	/**
	Ensures that the server is ready to perform requests before calling the callback.
	
	Being "ready" in this case entails holding on to an `Auth` instance. Such an instance is automatically created if either the client
	init settings are sufficient (i.e. contain an "authorize_uri" and optionally a "token_uri") or after the conformance statement has been
	fetched.
	*/
	public func ready(callback: (error: NSError?) -> ()) {
		if nil != auth {
			callback(error: nil)
			return
		}
		
		// if we haven't initialized the auth instance we likely didn't fetch the server metadata yet
		getConformance { error in
			if nil != self.auth {
				callback(error: nil)
			}
			else {
				callback(error: error ?? genSMARTError("Failed to detect the authorization method from server metadata"))
			}
		}
	}
	
	/**
	Ensures that the receiver is ready, then calls the auth method's `authorize()` method.
	*/
	public func authorize(authProperties: SMARTAuthProperties, callback: ((patient: Patient?, error: NSError?) -> Void)) {
		self.ready { error in
			if nil != error || nil == self.auth {
				callback(patient: nil, error: error ?? genSMARTError("Client error, no auth instance created"))
			}
			else {
				self.auth!.authorize(authProperties) { parameters, error in
					if nil != error {
						callback(patient: nil, error: error)
					}
					else if let patient = parameters?["patient_resource"] as? Patient {		// native patient list auth flow will deliver a Patient instance
						callback(patient: patient, error: nil)
					}
					else if let patientId = parameters?["patient"] as? String {
						Patient.read(patientId, server: self) { resource, error in
							logIfDebug("Did read patient \(resource) with error \(error)")
							callback(patient: resource as? Patient, error: error)
						}
					}
					else {
						callback(patient: nil, error: nil)
					}
				}
			}
		}
	}
	
	/**
	Resets authorization state - including deletion of any known access and refresh tokens.
	*/
	func reset() {
		abortSession()
		auth?.reset()
	}
	
	
	// MARK: - Registration
	
	/**
	Given an `OAuth2DynReg` instance, checks if the OAuth2 handler has client-id/secret, and if not attempts to register. Experimental.
	*/
	public func ensureRegistered(dynreg: OAuth2DynReg, callback: ((json: OAuth2JSON?, error: NSError?) -> Void)) {
		ready() { error in
			if let oauth = self.auth?.oauth {
				dynreg.registerIfNeededAndUpdateClient(oauth) { json, error in
					callback(json: json, error: error)
				}
			}
			else {
				callback(json: nil, error: genSMARTError("No OAuth2 handle, cannot register client"))
			}
		}
	}
	
	
	// MARK: - Requests
	
	/**
	    Method to execute a given request with a given request/response handler.
	
	    :param: path The path, relative to the server's base; may include URL query and URL fragment (!)
	    :param: handler The RequestHandler that prepares the request and processes the response
	    :param: callback The callback to execute; NOT guaranteed to be performed on the main thread!
	 */
	public func performRequestAgainst<R: FHIRServerRequestHandler>(path: String, handler: R, callback: ((response: R.ResponseType) -> Void)) {
		if let url = NSURL(string: path, relativeToURL: baseURL) {
			let request = auth?.signedRequest(url) ?? NSMutableURLRequest(URL: url)
			var error: NSError?
			if handler.prepareRequest(request, error: &error) {
				self.performPreparedRequest(request, handler: handler, callback: callback)
			}
			else {
				let err = error?.localizedDescription ?? "if only I knew why (\(__FILE__):\(__LINE__))"
				callback(response: handler.notSent("Failed to prepare request against \(url): \(err)"))
			}
		}
		else {
			let res = handler.notSent("Failed to parse path \(path) relative to base URL \(baseURL)")
			callback(response: res)
		}
	}
	
	/**
	    Method to execute an already prepared request and use the given request/response handler.
	
	    This implementation uses the instance's NSURLSession to execute data tasks with the requests. Subclasses can
	    override to supply different NSURLSessions based on the request, if so desired.
	
	    :param: request The URL request to perform
	    :param: handler The RequestHandler that prepares the request and processes the response
	    :param: callback The callback to execute; NOT guaranteed to be performed on the main thread!
	 */
	public func performPreparedRequest<R: FHIRServerRequestHandler>(request: NSMutableURLRequest, handler: R, callback: ((response: R.ResponseType) -> Void)) {
		performPreparedRequest(request, withSession: URLSession(), handler: handler, callback: callback)
	}
	
	/**
	    Method to execute an already prepared request with a given session and use the given request/response handler.
	
	    :param: request The URL request to perform
	    :param: withSession The NSURLSession instance to use
	    :param: handler The RequestHandler that prepares the request and processes the response
	    :param: callback The callback to execute; NOT guaranteed to be performed on the main thread!
	 */
	public func performPreparedRequest<R: FHIRServerRequestHandler>(request: NSMutableURLRequest, withSession session: NSURLSession, handler: R, callback: ((response: R.ResponseType) -> Void)) {
		let task = session.dataTaskWithRequest(request) { data, response, error in
			let res = handler.response(response: response, data: data)
			if nil != error {
				res.error = error
			}
			
			logIfDebug("Server responded with status \(res.status)")
			//let str = NSString(data: data!, encoding: NSUTF8StringEncoding)
			//logIfDebug("\(str)")
			callback(response: res)
		}
		
		logIfDebug("Performing \(handler.type.rawValue) request against \(request.URL!)")
		task.resume()
	}
	
	
	// MARK: - Operations
	
	func conformanceOperation(name: String) -> ConformanceRestOperation? {
		if let defs = conformanceOperations {
			for def in defs {
				if name == def.name {
					return def
				}
			}
		}
		return nil
	}
	
	/**
	    Retrieve the operation definition with the given name, either from cache or load the resource.
	
	    Once an OperationDefinition has been retrieved, it is cached into the instance's `operations` dictionary. Must
	    be used after the conformance statement has been fetched, i.e. after using `ready` or `getConformance`.
	 */
	public func operation(name: String, callback: (OperationDefinition? -> Void)) {
		if let op = operations?[name] {
			callback(op)
		}
		else if let def = conformanceOperation(name) {
			def.definition?.resolve(OperationDefinition.self) { optop in
				if let op = optop {
					if nil != self.operations {
						self.operations![name] = op
					}
					else {
						self.operations = [name: op]
					}
				}
				callback(optop)
			}
		}
		else {
			callback(nil)
		}
	}
	
	/**
	    Performs the given Operation.
	
	    `Resource` has extensions to facilitate working with operations, be sure to take a look.
	
	    :param: operation The operation instance to perform
	    :param: callback The callback to call when the request ends (success or failure)
	 */
	public func performOperation(operation: FHIROperation, callback: ((response: FHIRServerJSONResponse) -> Void)) {
		self.operation(operation.name) { definition in
			if let def = definition {
				var error: NSError?
				if operation.validateWith(def, error: &error) {
					operation.perform(self, callback: callback)
				}
				else {
					callback(response: FHIRServerJSONResponse(notSentBecause: error ?? genServerError("Unknown validation error with operation \(operation)")))
				}
			}
			else {
				callback(response: FHIRServerJSONResponse(notSentBecause: genServerError("The server does not support operation \(operation)")))
			}
		}
	}
	
	
	// MARK: - Session Management
	
	final public func URLSession() -> NSURLSession {
		if nil == session {
			session = createDefaultSession()
		}
		return session!
	}
	
	/** Create the server's default session. Override in subclasses to customize NSURLSession behavior. */
	public func createDefaultSession() -> NSURLSession {
		if let delegate = sessionDelegate {
			return NSURLSession(configuration: NSURLSessionConfiguration.defaultSessionConfiguration(), delegate: delegate, delegateQueue: nil)
		}
		return NSURLSession.sharedSession()
	}
	
	func abortSession() {
		if nil != auth {
			auth!.abort()
		}
		
		if nil != session {
			session!.invalidateAndCancel()
			session = nil
		}
	}
}

