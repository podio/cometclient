
#import <Security/Security.h>
#import "DDCometLongPollingTransport.h"
#import "DDCometClient.h"
#import "DDCometMessage.h"
#import "DDQueue.h"
#import "DDSecurityHelpers.h"

@interface DDCometLongPollingTransport ()

@property (nonatomic, copy, readonly) NSSet *pinnedPublicKeys;

@end

@implementation DDCometLongPollingTransport

@synthesize pinnedPublicKeys = m_pinnedPublicKeys;

- (id)initWithClient:(DDCometClient *)client
{
	if ((self = [super init]))
	{
		m_client = [client retain];
		m_responseDatas = [[NSMutableDictionary alloc] initWithCapacity:2];
	}
	return self;
}

- (void)dealloc
{
	[m_pinnedPublicKeys release];
	[m_responseDatas release];
	[m_client release];
	[super dealloc];
}

- (void)start
{
	[self performSelectorInBackground:@selector(main) withObject:nil];
}

- (void)cancel
{
	m_shouldCancel = YES;
}

- (NSSet *)pinnedPublicKeys {
	if (!m_pinnedPublicKeys) {
		NSMutableSet *publicKeys = [NSMutableSet new];
		
		NSArray *paths = [[NSBundle bundleForClass:[self class]] pathsForResourcesOfType:@"cer" inDirectory:@"."];
		for (NSString *path in paths) {
			NSData *certData = [NSData dataWithContentsOfFile:path];
   
			if (certData) {
				SecCertificateRef cert = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)certData);
				
				if (cert) {
					id publicKey = DDPublicKeyForCertificate(cert);
					[publicKeys addObject:(id)publicKey];
					CFRelease(cert);
				}
			}
		}
		
		m_pinnedPublicKeys = [publicKeys copy];
		[publicKeys release];
	}
	
	return m_pinnedPublicKeys;
}

- (BOOL)comparePublicKeysOfBundledCertificatesToCertificate:(SecCertificateRef)cert {
	NSParameterAssert(cert != NULL);
	
	BOOL matches = NO;
	
	id publicKey = DDPublicKeyForCertificate(cert);
	for (id pinnedPublicKey in self.pinnedPublicKeys) {
		matches = DDKeyIsEqualToKey((__bridge SecKeyRef)publicKey, (__bridge SecKeyRef)pinnedPublicKey);
		
		if (matches) {
			break;
		}
	}
	
	return matches;
}

#pragma mark -

- (void)main
{
	do
	{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSArray *messages = [self outgoingMessages];
		
		BOOL isPolling = NO;
		if ([messages count] == 0)
		{
			if (m_client.state == DDCometStateConnected)
			{
				isPolling = YES;
				DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/connect"];
				message.clientID = m_client.clientID;
				message.connectionType = @"long-polling";
				messages = [NSArray arrayWithObject:message];
			}
			else
			{
				[NSThread sleepForTimeInterval:0.01];
			}
		}
		
		NSArray *connections = [self sendMessages:messages];
		NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
		while ([runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]])
		{
			if (isPolling)
			{
				if (m_shouldCancel)
				{
					m_shouldCancel = NO;
					for (NSURLConnection *connection in connections) {
						[connection cancel];
					}
				}
				else
				{
					messages = [self outgoingMessages];
					[self sendMessages:messages];
				}
			}
		}
		
		[pool release];
	} while (m_client.state != DDCometStateDisconnected);
}

- (NSArray *)sendMessages:(NSArray *)messages {
	NSMutableArray *connections = [NSMutableArray array];
	
	for (DDCometMessage *message in messages) {
		NSURLConnection *connection = [self sendMessage:message];
		if (connection) {
			[connections addObject:connection];
		}
	}
	
	return [[connections copy] autorelease];
}

- (NSURLConnection *)sendMessage:(DDCometMessage *)message {
	NSURLRequest *request = [self requestForMessage:message];
	NSURLConnection *connection = [NSURLConnection connectionWithRequest:request delegate:self];
	
	if (connection) {
		DDCometClientLog(@"-> SENDING MSG (channel:%@, client-id:%@)", message.channel, message.clientID);
		NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
		[connection scheduleInRunLoop:runLoop forMode:[runLoop currentMode]];
		[connection start];
	}
	
	return connection;
}

- (NSArray *)outgoingMessages
{
	NSMutableArray *messages = [NSMutableArray array];
	DDCometMessage *message;
	id<DDQueue> outgoingQueue = [m_client outgoingQueue];
	while ((message = [outgoingQueue removeObject]))
		[messages addObject:message];
	return messages;
}

- (NSURLRequest *)requestForMessage:(DDCometMessage *)message
{
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:m_client.endpointURL];
	
	NSArray *messagesData = @[[message proxyForJson]];
	NSData *body = [NSJSONSerialization dataWithJSONObject:messagesData options:0 error:nil];
	
	[request setHTTPMethod:@"POST"];
	[request setValue:@"application/json;charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
	[request setHTTPBody:body];
	
	NSNumber *timeout = [m_client.advice objectForKey:@"timeout"];
	if (timeout)
		[request setTimeoutInterval:([timeout floatValue] / 1000)];
	
	return request;
}

- (id)keyWithConnection:(NSURLConnection *)connection
{
	return [NSNumber numberWithUnsignedInteger:[connection hash]];
}

#pragma mark - NSURLConnectionDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
	[m_responseDatas setObject:[NSMutableData data] forKey:[self keyWithConnection:connection]];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
	NSMutableData *responseData = [m_responseDatas objectForKey:[self keyWithConnection:connection]];
	[responseData appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
	NSData *responseData = [[m_responseDatas objectForKey:[self keyWithConnection:connection]] retain];
	[m_responseDatas removeObjectForKey:[self keyWithConnection:connection]];
	
	NSArray *responses = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
	[responseData release];
	responseData = nil;
	
	id<DDQueue> incomingQueue = [m_client incomingQueue];
	
	for (NSDictionary *messageData in responses)
	{
		DDCometMessage *message = [DDCometMessage messageWithJson:messageData];
		DDCometClientLog(@"-> RECEIVED MSG (channel:%@, clientid:%@)", message.channel, message.clientID);
		
		[incomingQueue addObject:message];
	}
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
	[m_responseDatas removeObjectForKey:[self keyWithConnection:connection]];
}

- (void)connection:(NSURLConnection *)connection willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
	if (!m_client.usesSSLPublicKeyPinning) {
		[challenge.sender performDefaultHandlingForAuthenticationChallenge:challenge];
		return;
	}
	
	SecTrustRef serverTrust = challenge.protectionSpace.serverTrust;
	SecCertificateRef certificate = DDFirstCertificateFromTrust(serverTrust);
	
	if (certificate != NULL && [self comparePublicKeysOfBundledCertificatesToCertificate:certificate]) {
		NSURLCredential *credential = [NSURLCredential credentialForTrust:serverTrust];
		[challenge.sender useCredential:credential forAuthenticationChallenge:challenge];
	}
	else {
		[challenge.sender cancelAuthenticationChallenge:challenge];
	}
}

@end
