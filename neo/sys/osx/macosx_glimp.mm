/*
===========================================================================

Doom 3 GPL Source Code
Copyright (C) 1999-2011 id Software LLC, a ZeniMax Media company. 

This file is part of the Doom 3 GPL Source Code (?Doom 3 Source Code?).  

Doom 3 Source Code is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Doom 3 Source Code is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Doom 3 Source Code.  If not, see <http://www.gnu.org/licenses/>.

In addition, the Doom 3 Source Code is also subject to certain additional terms. You should have received a copy of these additional terms immediately following the terms and conditions of the GNU General Public License which accompanied the Doom 3 Source Code.  If not, please request a copy in writing from id Software at the address below.

If you have questions concerning this license or the applicable additional terms, you may contact in writing id Software LLC, c/o ZeniMax Media Inc., Suite 120, Rockville, Maryland 20850 USA.

===========================================================================
*/

// -*- mode: objc -*-
#import "../../idlib/precompiled.h"

#import "../../renderer/tr_local.h"

#import "macosx_glimp.h"

#import "macosx_local.h"
#import "macosx_sys.h"
#import "macosx_display.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <mach/mach_error.h>

static idCVar r_minDisplayRefresh( "r_minDisplayRefresh", "0", CVAR_ARCHIVE | CVAR_INTEGER, "" );
static idCVar r_maxDisplayRefresh( "r_maxDisplayRefresh", "0", CVAR_ARCHIVE | CVAR_INTEGER, "" );
static idCVar r_screen( "r_screen", "-1", CVAR_ARCHIVE | CVAR_INTEGER, "which display to use" );

static void				GLW_InitExtensions( void );
static bool				CreateGameWindow( glimpParms_t parms );
static unsigned long	Sys_QueryVideoMemory();
CGDisplayErr		Sys_CaptureActiveDisplays(void);

glwstate_t glw_state;
static bool isHidden = false;

@interface NSOpenGLContext (CGLContextAccess)
- (CGLContextObj) cglContext;
@end

@implementation NSOpenGLContext (CGLContextAccess)
- (CGLContextObj) cglContext;
{
	return [self CGLContextObj];
}
@end

/*
============
CheckErrors
============
*/
void CheckErrors( void ) {		
	GLenum   err;

	err = glGetError();
	if ( err != GL_NO_ERROR ) {
		common->Error( "glGetError: %s\n", glGetString( err ) );
	}
}

/*
** GLimp_SetMode
*/

bool GLimp_SetMode(  glimpParms_t parms ) {
	if ( !CreateGameWindow( parms ) ) {
		common->Printf( "GLimp_SetMode: window could not be created!\n" );
		return false;
	}

	glConfig.vidWidth = parms.width;
	glConfig.vidHeight = parms.height;
	glConfig.isFullscreen = parms.fullScreen;
    
	// draw something to show that GL is alive	
	glClearColor( 0.5, 0.5, 0.7, 0 );
	glClear( GL_COLOR_BUFFER_BIT );
	GLimp_SwapBuffers();
        
	glClearColor( 0.5, 0.5, 0.7, 0 );
	glClear( GL_COLOR_BUFFER_BIT );
	GLimp_SwapBuffers();

	Sys_UnfadeScreen( Sys_DisplayToUse(), NULL );
    
	CheckErrors();

	return true;
}

/*
=================
GetPixelAttributes
=================
*/

#define ADD_ATTR(x)	\
	do {								   \
		if (attributeIndex >= attributeSize) {	\
			attributeSize *= 2;	\
			pixelAttributes = (NSOpenGLPixelFormatAttribute *)NSZoneRealloc(NULL, pixelAttributes, sizeof(*pixelAttributes) * attributeSize); \
		} \
		pixelAttributes[attributeIndex] = (NSOpenGLPixelFormatAttribute)x;	\
		attributeIndex++;						\
		if ( verbose ) {												\
			common->Printf( "Adding pixel attribute: %d (%s)\n", x, #x); \
		}																\
	} while(0)

static NSOpenGLPixelFormatAttribute *GetPixelAttributes( unsigned int multisamples ) {
	NSOpenGLPixelFormatAttribute *pixelAttributes;
	unsigned int attributeIndex = 0;
	unsigned int attributeSize = 128;
	int verbose;
	unsigned int colorDepth;
	unsigned int desktopColorDepth;
	unsigned int depthBits;
	unsigned int stencilBits;
	unsigned int buffers;
    
	verbose = 0;
    
	pixelAttributes = (NSOpenGLPixelFormatAttribute *)NSZoneMalloc(NULL, sizeof(*pixelAttributes) * attributeSize);

	// only greater or equal attributes will be selected
	ADD_ATTR( NSOpenGLPFAMinimumPolicy );
	ADD_ATTR( 1 );

	if ( cvarSystem->GetCVarBool( "r_fullscreen" ) ) {
		ADD_ATTR(NSOpenGLPFAFullScreen);
	}

	ADD_ATTR(NSOpenGLPFAScreenMask);
	ADD_ATTR(CGDisplayIDToOpenGLDisplayMask(Sys_DisplayToUse()));
	
	// Require hardware acceleration
	ADD_ATTR(NSOpenGLPFAAccelerated);

	// Require double-buffer
	ADD_ATTR(NSOpenGLPFADoubleBuffer);

	// color bits
	ADD_ATTR(NSOpenGLPFAColorSize);
	colorDepth = 32;
	if ( !cvarSystem->GetCVarBool( "r_fullscreen" ) ) {
		desktopColorDepth = [[glw_state.desktopMode objectForKey: (id)kCGDisplayBitsPerPixel] intValue];
		if ( desktopColorDepth != 32 ) {
			common->Warning( "Desktop display colors should be 32 bits for window rendering" );
		}
	}
	ADD_ATTR(colorDepth);

	// Specify the number of depth bits
	ADD_ATTR( NSOpenGLPFADepthSize );
	depthBits = 24;
	ADD_ATTR( depthBits );

	// Specify the number of stencil bits
	stencilBits = 8;
	ADD_ATTR( NSOpenGLPFAStencilSize );
	ADD_ATTR( stencilBits );

	// Specify destination alpha
	ADD_ATTR( NSOpenGLPFAAlphaSize );
	ADD_ATTR( 8 );

	if ( multisamples ) {
		buffers = 1;
		ADD_ATTR( NSOpenGLPFASampleBuffers );	
		ADD_ATTR( buffers );
		ADD_ATTR( NSOpenGLPFASamples );	
		ADD_ATTR( multisamples );
	}

	// Terminate the list
	ADD_ATTR(0);
    
	return pixelAttributes;
}

void Sys_UpdateWindowMouseInputRect(void) {		
	/*
    NSRect           windowRect, screenRect;
	NSScreen        *screen;

	// TTimo - I guess glw_state.window is bogus .. getting crappy data out of this

	// It appears we need to flip the coordinate system here.  This means we need
	// to know the size of the screen.
	screen = [glw_state.window screen];
	screenRect = [screen frame];
	windowRect = [glw_state.window frame];
	windowRect.origin.y = screenRect.size.height - (windowRect.origin.y + windowRect.size.height);

	Sys_SetMouseInputRect( CGRectMake( windowRect.origin.x, windowRect.origin.y, windowRect.size.width, windowRect.size.height ) );
	*/

	Sys_SetMouseInputRect( CGDisplayBounds( glw_state.display ) );
}							

// This is needed since CGReleaseAllDisplays() restores the gamma on the displays and we want to fade it up rather than just flickering all the displays
static void ReleaseAllDisplays() {
	CGDisplayCount displayIndex;

	common->Printf("Releasing displays\n");
	for (displayIndex = 0; displayIndex < glw_state.displayCount; displayIndex++) {
		CGDisplayRelease(glw_state.originalDisplayGammaTables[displayIndex].display);
	}
}

/*
=================
CreateGameWindow
=================
*/
static bool CreateGameWindow(  glimpParms_t parms ) {
	const char						*windowed[] = { "Windowed", "Fullscreen" };
	NSOpenGLPixelFormatAttribute	*pixelAttributes;
	NSOpenGLPixelFormat				*pixelFormat;
	CGDisplayErr					err;
	unsigned int					multisamples;
            
	glw_state.display = Sys_DisplayToUse();
	glw_state.desktopMode = (NSDictionary *)CGDisplayCurrentMode( glw_state.display );
	if ( !glw_state.desktopMode ) {
		common->Error( "Could not get current graphics mode for display 0x%08x\n", glw_state.display );
	}

	common->Printf(  " %d %d %s\n", parms.width, parms.height, windowed[ parms.fullScreen ] );

	if (parms.fullScreen) {
        
		// We'll set up the screen resolution first in case that effects the list of pixel
		// formats that are available (for example, a smaller frame buffer might mean more
		// bits for depth/stencil buffers).  Allow stretched video modes if we are in fallback mode.
		glw_state.gameMode = Sys_GetMatchingDisplayMode(parms);
		if (!glw_state.gameMode) {
			common->Printf(  "Unable to find requested display mode.\n");
			return false;
		}

		// Fade all screens to black
		//        Sys_FadeScreens();
        
		err = Sys_CaptureActiveDisplays();
		if ( err != CGDisplayNoErr ) {
			CGDisplayRestoreColorSyncSettings();
			common->Printf(  " Unable to capture displays err = %d\n", err );
			return false;
		}

		err = CGDisplaySwitchToMode(glw_state.display, (CFDictionaryRef)glw_state.gameMode);
		if ( err != CGDisplayNoErr ) {
			CGDisplayRestoreColorSyncSettings();
			ReleaseAllDisplays();
			common->Printf(  " Unable to set display mode, err = %d\n", err );
			return false;
		}
	} else {
		glw_state.gameMode = glw_state.desktopMode;
	}
    
	// Get the GL pixel format
	pixelFormat = nil;
	multisamples = cvarSystem->GetCVarInteger( "r_multiSamples" );
	while ( !pixelFormat ) {
		pixelAttributes = GetPixelAttributes( multisamples );
		pixelFormat = [[[NSOpenGLPixelFormat alloc] initWithAttributes: pixelAttributes] autorelease];
		NSZoneFree(NULL, pixelAttributes);
		if ( pixelFormat || multisamples == 0 )
			break;
		multisamples >>= 1;
	}
	cvarSystem->SetCVarInteger( "r_multiSamples", multisamples );			
    
	if (!pixelFormat) {
		CGDisplayRestoreColorSyncSettings();
		CGDisplaySwitchToMode(glw_state.display, (CFDictionaryRef)glw_state.desktopMode);
		ReleaseAllDisplays();
		common->Printf(  " No pixel format found\n");
		return false;
	}

	// Create a context with the desired pixel attributes
	OSX_SetGLContext([[NSOpenGLContext alloc] initWithFormat: pixelFormat shareContext: nil]);
	if ( !OSX_GetNSGLContext() ) {
		CGDisplayRestoreColorSyncSettings();
		CGDisplaySwitchToMode(glw_state.display, (CFDictionaryRef)glw_state.desktopMode);
		ReleaseAllDisplays();
		common->Printf(  "... +[NSOpenGLContext createWithFormat:share:] failed.\n" );
		return false;
	}
#ifdef __ppc__
	long system_version = 0;
	Gestalt( gestaltSystemVersion, &system_version );
	if ( parms.width <= 1024 && parms.height <= 768 && system_version <= 0x1045 ) {
		[ OSX_GetNSGLContext() setValues: &swap_limit forParameter: (NSOpenGLContextParameter)nsOpenGLCPSwapLimit ];
	}
#endif
	
	if ( !parms.fullScreen ) {
		NSScreen*		 screen;
		NSRect           windowRect;
		int				 displayIndex;
		int				 displayCount;
		
		displayIndex = r_screen.GetInteger();
		displayCount = [[NSScreen screens] count];
		if ( displayIndex < 0 || displayIndex >= displayCount ) {
			screen = [NSScreen mainScreen];
		} else {
			screen = [[NSScreen screens] objectAtIndex:displayIndex];
		}

		NSRect r = [screen frame];
		windowRect.origin.x =  ((short)r.size.width - parms.width) / 2;
		windowRect.origin.y  = ((short)r.size.height - parms.height) / 2;
		windowRect.size.width = parms.width;
		windowRect.size.height = parms.height;
        
		glw_state.window = [NSWindow alloc];
		[glw_state.window initWithContentRect:windowRect styleMask:NSTitledWindowMask backing:NSBackingStoreRetained defer:NO screen:screen];
                                                           
		[glw_state.window setTitle: @GAME_NAME];

		[glw_state.window orderFront: nil];

		// Always get mouse moved events (if mouse support is turned off (rare)
		// the event system will filter them out.
		[glw_state.window setAcceptsMouseMovedEvents: YES];
        
		// Direct the context to draw in this window
		[OSX_GetNSGLContext() setView: [glw_state.window contentView]];

		// Sync input rect with where the window actually is...
		Sys_UpdateWindowMouseInputRect();
	} else {
		CGLError err;

		glw_state.window = NULL;
        
		err = CGLSetFullScreen(OSX_GetCGLContext());
		if (err) {
			CGDisplayRestoreColorSyncSettings();
			CGDisplaySwitchToMode(glw_state.display, (CFDictionaryRef)glw_state.desktopMode);
			ReleaseAllDisplays();
			common->Printf("CGLSetFullScreen -> %d (%s)\n", err, CGLErrorString(err));
			return false;
		}

		Sys_SetMouseInputRect( CGDisplayBounds( glw_state.display ) );
	}

#ifndef USE_CGLMACROS
	// Make this the current context
	OSX_GLContextSetCurrent();
#endif

	// Store off the pixel format attributes that we actually got
	[pixelFormat getValues: (int *) &glConfig.colorBits forAttribute: NSOpenGLPFAColorSize forVirtualScreen: 0];
	[pixelFormat getValues: (int *) &glConfig.depthBits forAttribute: NSOpenGLPFADepthSize forVirtualScreen: 0];
	[pixelFormat getValues: (int *) &glConfig.stencilBits forAttribute: NSOpenGLPFAStencilSize forVirtualScreen: 0];

	glConfig.displayFrequency = [[glw_state.gameMode objectForKey: (id)kCGDisplayRefreshRate] intValue];
    
	common->Printf(  "ok\n" );

	return true;
}

// This can be used to temporarily disassociate the GL context from the screen so that CoreGraphics can be used to draw to the screen.
void Sys_PauseGL () {
	if (!glw_state.glPauseCount) {
		glFinish (); // must do this to ensure the queue is complete
        
		// Have to call both to actually deallocate kernel resources and free the NSSurface
		CGLClearDrawable(OSX_GetCGLContext());
		[OSX_GetNSGLContext() clearDrawable];
	}
	glw_state.glPauseCount++;
}

// This can be used to reverse the pausing caused by Sys_PauseGL()
void Sys_ResumeGL () {
	if (glw_state.glPauseCount) {
		glw_state.glPauseCount--;
		if (!glw_state.glPauseCount) {
			if (!glConfig.isFullscreen) {
				[OSX_GetNSGLContext() setView: [glw_state.window contentView]];
			} else {
				CGLError err;
                
				err = CGLSetFullScreen(OSX_GetCGLContext());
				if (err)
					common->Printf("CGLSetFullScreen -> %d (%s)\n", err, CGLErrorString(err));
			}
		}
	}
}

/*
===================
GLimp_Init

Don't return unless OpenGL has been properly initialized
===================
*/

#ifdef OMNI_TIMER
static void GLImp_Dump_Stamp_List_f(void) {
	OTStampListDumpToFile(glThreadStampList, "/tmp/gl_stamps");
}
#endif

bool GLimp_Init( glimpParms_t parms ) {
	char *buf;

	common->Printf(  "Initializing OpenGL subsystem\n" );
	common->Printf(  "  fullscreen: %s\n", cvarSystem->GetCVarBool( "r_fullscreen" ) ? "yes" : "no" );

	Sys_StoreGammaTables();
    
	if ( !Sys_QueryVideoMemory() ) {
		common->Error(  "Could not initialize OpenGL.  There does not appear to be an OpenGL-supported video card in your system.\n" );
	}
    
	if ( !GLimp_SetMode( parms ) ) {
		common->Warning(  "Could not initialize OpenGL\n" );
		return false;
	}

	common->Printf(  "------------------\n" );
    
    GLenum glewResult = glewInit();
    if( GLEW_OK != glewResult )
    {
        // glewInit failed, something is seriously wrong
        common->Printf( "^3GLimp_Init() - GLEW could not load OpenGL subsystem: %s", glewGetErrorString( glewResult ) );
    }
    else
    {
        common->Printf( "Using GLEW %s\n", glewGetString( GLEW_VERSION ) );
    }

	// get our config strings
	glConfig.vendor_string = (const char *)glGetString( GL_VENDOR );
	glConfig.renderer_string = (const char *)glGetString( GL_RENDERER );
	glConfig.version_string = (const char *)glGetString( GL_VERSION );

	//
	// chipset specific configuration
	//
	buf = (char *)malloc(strlen(glConfig.renderer_string) + 1);
	strcpy( buf, glConfig.renderer_string );

	//	Cvar_Set( "r_lastValidRenderer", glConfig.renderer_string );
	free(buf);

	GLW_InitExtensions();

	/*    
#ifndef USE_CGLMACROS
	if (!r_enablerender->integer)
		OSX_GLContextClearCurrent();
#endif
	*/
	return true;
}


/*
** GLimp_SwapBuffers
** 
** Responsible for doing a swapbuffers and possibly for other stuff
** as yet to be determined.  Probably better not to make this a GLimp
** function and instead do a call to GLimp_SwapBuffers.
*/
void GLimp_SwapBuffers( void ) {
	if ( r_swapInterval.IsModified() ) {
		r_swapInterval.ClearModified();
	}

	if (!glw_state.glPauseCount && !isHidden) {
		glw_state.bufferSwapCount++;
		[OSX_GetNSGLContext() flushBuffer];
	}

	/*    
	// Enable turning off GL at any point for performance testing
	if (OSX_GLContextIsCurrent() != r_enablerender->integer) {
		if (r_enablerender->integer) {
			common->Printf("--- Enabling Renderer ---\n");
			OSX_GLContextSetCurrent();
		} else {
			common->Printf("--- Disabling Renderer ---\n");
			OSX_GLContextClearCurrent();
		}
	}
	*/
}

/*
** GLimp_Shutdown
**
** This routine does all OS specific shutdown procedures for the OpenGL
** subsystem.  Under OpenGL this means NULLing out the current DC and
** HGLRC, deleting the rendering context, and releasing the DC acquired
** for the window.  The state structure is also nulled out.
**
*/

static void _GLimp_RestoreOriginalVideoSettings() {
	CGDisplayErr err;
    
	// CGDisplayCurrentMode lies because we've captured the display and thus we won't
	// get any notifications about what the current display mode really is.  For now,
	// we just always force it back to what mode we remember the desktop being in.
	if (glConfig.isFullscreen) {
		err = CGDisplaySwitchToMode(glw_state.display, (CFDictionaryRef)glw_state.desktopMode);
		if ( err != CGDisplayNoErr )
			common->Printf(  " Unable to restore display mode!\n" );

		ReleaseAllDisplays();
	}
}

void GLimp_Shutdown( void ) {
	CGDisplayCount displayIndex;

	common->Printf("----- Shutting down GL -----\n");

	Sys_FadeScreen(Sys_DisplayToUse());
    
	if (OSX_GetNSGLContext()) {
#ifndef USE_CGLMACROS
		OSX_GLContextClearCurrent();
#endif
		// Have to call both to actually deallocate kernel resources and free the NSSurface
		CGLClearDrawable(OSX_GetCGLContext());
		[OSX_GetNSGLContext() clearDrawable];
        
		[OSX_GetNSGLContext() release];
		OSX_SetGLContext((id)nil);
	}

	_GLimp_RestoreOriginalVideoSettings();
    
	Sys_UnfadeScreens();

	// Restore the original gamma if needed.
	//    if (glConfig.deviceSupportsGamma) {
	//        common->Printf("Restoring ColorSync settings\n");
	//        CGDisplayRestoreColorSyncSettings();
	//    }

	if (glw_state.window) {
		[glw_state.window release];
		glw_state.window = nil;
	}

	if (glw_state.log_fp) {
		fclose(glw_state.log_fp);
		glw_state.log_fp = 0;
	}

	for (displayIndex = 0; displayIndex < glw_state.displayCount; displayIndex++) {
		free(glw_state.originalDisplayGammaTables[displayIndex].red);
		free(glw_state.originalDisplayGammaTables[displayIndex].blue);
		free(glw_state.originalDisplayGammaTables[displayIndex].green);
	}
	free(glw_state.originalDisplayGammaTables);
	if (glw_state.tempTable.red) {
		free(glw_state.tempTable.red);
		free(glw_state.tempTable.blue);
		free(glw_state.tempTable.green);
	}
	if (glw_state.inGameTable.red) {
		free(glw_state.inGameTable.red);
		free(glw_state.inGameTable.blue);
		free(glw_state.inGameTable.green);
	}
    
	memset(&glConfig, 0, sizeof(glConfig));
	//    memset(&glState, 0, sizeof(glState));
	memset(&glw_state, 0, sizeof(glw_state));

	common->Printf("----- Done shutting down GL -----\n");
}

/*
===============
GLimp_LogComment
===============
*/
void	GLimp_LogComment( char *comment ) { }

/*
===============
GLimp_SetGamma
===============
*/
void GLimp_SetGamma(unsigned short red[256],
                    unsigned short green[256],
                    unsigned short blue[256]) {
	CGGammaValue redGamma[256], greenGamma[256], blueGamma[256];
	CGTableCount i;
	CGDisplayErr err;
        
	for (i = 0; i < 256; i++) {
		redGamma[i]   = red[i]   / 65535.0;
		greenGamma[i] = green[i] / 65535.0;
		blueGamma[i]  = blue[i]  / 65535.0;
	}
    
	err = CGSetDisplayTransferByTable(glw_state.display, 256, redGamma, greenGamma, blueGamma);
	if (err != CGDisplayNoErr) {
		common->Printf("GLimp_SetGamma: CGSetDisplayTransferByByteTable returned %d.\n", err);
	}
    
	// Store the gamma table that we ended up using so we can reapply it later when unhiding or to work around the bug where if you leave the game sitting and the monitor sleeps, when it wakes, the gamma isn't reset.
	glw_state.inGameTable.display = glw_state.display;
	Sys_GetGammaTable(&glw_state.inGameTable);
}

/*****************************************************************************/

/*
** GLW_InitExtensions
*/
void GLW_InitExtensions( void ) { }

#define MAX_RENDERER_INFO_COUNT 128

// Returns zero if there are no hardware renderers.  Otherwise, returns the max memory across all renderers (on the presumption that the screen that we'll use has the most memory).
unsigned long Sys_QueryVideoMemory() {
	CGLError err;
	CGLRendererInfoObj rendererInfo, rendererInfos[MAX_RENDERER_INFO_COUNT];
	long rendererInfoIndex;
    GLint rendererInfoCount = MAX_RENDERER_INFO_COUNT;
	long rendererIndex;
    GLint rendererCount;
	long maxVRAM = 0;
    GLint vram = 0;
	GLint accelerated;
	GLint rendererID;
	long totalRenderers = 0;
    
	err = CGLQueryRendererInfo(CGDisplayIDToOpenGLDisplayMask(Sys_DisplayToUse()), rendererInfos, &rendererInfoCount);
	if (err) {
		common->Printf("CGLQueryRendererInfo -> %d\n", err);
		return vram;
	}
    
	//common->Printf("rendererInfoCount = %d\n", rendererInfoCount);
	for (rendererInfoIndex = 0; rendererInfoIndex < rendererInfoCount && totalRenderers < rendererInfoCount; rendererInfoIndex++) {
		rendererInfo = rendererInfos[rendererInfoIndex];
		//common->Printf("rendererInfo: 0x%08x\n", rendererInfo);
        

		err = CGLDescribeRenderer(rendererInfo, 0, kCGLRPRendererCount, &rendererCount);
		if (err) {
			common->Printf("CGLDescribeRenderer(kCGLRPRendererID) -> %d\n", err);
			continue;
		}
		//common->Printf("  rendererCount: %d\n", rendererCount);

		for (rendererIndex = 0; rendererIndex < rendererCount; rendererIndex++) {
			totalRenderers++;
			//common->Printf("  rendererIndex: %d\n", rendererIndex);
            
			rendererID = 0xffffffff;
			err = CGLDescribeRenderer(rendererInfo, rendererIndex, kCGLRPRendererID, &rendererID);
			if (err) {
				common->Printf("CGLDescribeRenderer(kCGLRPRendererID) -> %d\n", err);
				continue;
			}
			//common->Printf("    rendererID: 0x%08x\n", rendererID);
            
			accelerated = 0;
			err = CGLDescribeRenderer(rendererInfo, rendererIndex, kCGLRPAccelerated, &accelerated);
			if (err) {
				common->Printf("CGLDescribeRenderer(kCGLRPAccelerated) -> %d\n", err);
				continue;
			}
			//common->Printf("    accelerated: %d\n", accelerated);
			if (!accelerated)
				continue;
            
			vram = 0;
			err = CGLDescribeRenderer(rendererInfo, rendererIndex, kCGLRPVideoMemory, &vram);
			if (err) {
				common->Printf("CGLDescribeRenderer -> %d\n", err);
				continue;
			}
			//common->Printf("    vram: 0x%08x\n", vram);
            
			// presumably we'll be running on the best card, so we'll take the max of the vrams
			if (vram > maxVRAM)
				maxVRAM = vram;
		}
        
#if 0
		err = CGLDestroyRendererInfo(rendererInfo);
		if (err) {
			common->Printf("CGLDestroyRendererInfo -> %d\n", err);
		}
#endif
	}

	return maxVRAM;
}


// We will set the Sys_IsHidden global to cause input to be handle differently (we'll just let NSApp handle events in this case).  We also will unbind the GL context and restore the video mode.
bool Sys_Hide() {
	if ( isHidden ) {
		// Eh?
		return false;
	}
    
	if ( !r_fullscreen.GetBool() ) {
		// We only support hiding in fullscreen mode right now
		return false;
	}
    
	isHidden = true;

	// Don't need to store the current gamma since we always keep it around in glw_state.inGameTable.

	Sys_FadeScreen(Sys_DisplayToUse());

	// Disassociate the GL context from the screen
	// Have to call both to actually deallocate kernel resources and free the NSSurface
	CGLClearDrawable(OSX_GetCGLContext());
	[OSX_GetNSGLContext() clearDrawable];
    
	// Restore the original video mode
	_GLimp_RestoreOriginalVideoSettings();

	// Restore the original gamma if needed.
	//    if (glConfig.deviceSupportsGamma) {
	//        CGDisplayRestoreColorSyncSettings();
	//    }

	// Release the screen(s)
	ReleaseAllDisplays();
    
	Sys_UnfadeScreens();
    
	// Shut down the input system so the mouse and keyboard settings are restore to normal
	Sys_ShutdownInput();
    
	// Hide the application so that when the user clicks on our app icon, we'll get an unhide notification
	[NSApp hide: nil];
    
	return true;
}

CGDisplayErr Sys_CaptureActiveDisplays(void) {
	CGDisplayErr err;
	CGDisplayCount displayIndex;
	for (displayIndex = 0; displayIndex < glw_state.displayCount; displayIndex++) {
		const glwgamma_t *table;
		table = &glw_state.originalDisplayGammaTables[displayIndex];
		err = CGDisplayCapture(table->display);
		if (err != CGDisplayNoErr)
	    return err;
	}
	return CGDisplayNoErr;
}

bool Sys_Unhide() {
	CGDisplayErr err;
	CGLError glErr;
    
	if ( !isHidden) {
		// Eh?
		return false;
	}
        
	Sys_FadeScreens();

	// Capture the screen(s)
	err = Sys_CaptureActiveDisplays();
	if (err != CGDisplayNoErr) {
		Sys_UnfadeScreens();
		common->Printf(  "Unhide failed -- cannot capture the display again.\n" );
		return false;
	}
    
	// Restore the game mode
	err = CGDisplaySwitchToMode(glw_state.display, (CFDictionaryRef)glw_state.gameMode);
	if ( err != CGDisplayNoErr ) {
		ReleaseAllDisplays();
		Sys_UnfadeScreens();
		common->Printf(  "Unhide failed -- Unable to set display mode\n" );
		return false;
	}

	// Reassociate the GL context and the screen
	glErr = CGLSetFullScreen(OSX_GetCGLContext());
	if (glErr) {
		ReleaseAllDisplays();
		Sys_UnfadeScreens();
		common->Printf(  "Unhide failed: CGLSetFullScreen -> %d (%s)\n", err, CGLErrorString(glErr));
		return false;
	}

	// Restore the current context
	[OSX_GetNSGLContext() makeCurrentContext];
    
	// Restore the gamma that the game had set
	Sys_UnfadeScreen(Sys_DisplayToUse(), &glw_state.inGameTable);
    
	// Restore the input system (last so if something goes wrong we don't eat the mouse)
	Sys_InitInput();
    
	isHidden = false;
	return true;
}

bool GLimp_SpawnRenderThread( void (*function)( void ) ) {
	return false;
}

void *GLimp_RendererSleep(void) {
	return NULL;
}

void GLimp_FrontEndSleep(void) { }

void GLimp_WakeRenderer( void *data ) { }

void *GLimp_BackEndSleep( void ) {
	return NULL;
}

void GLimp_WakeBackEnd( void *data ) {
}

// enable / disable context is just for the r_skipRenderContext debug option
void GLimp_DeactivateContext( void ) {
	[NSOpenGLContext clearCurrentContext];
}

void GLimp_ActivateContext( void ) {
	[OSX_GetNSGLContext() makeCurrentContext];
}

NSDictionary *Sys_GetMatchingDisplayMode( glimpParms_t parms ) {
	NSArray *displayModes;
	NSDictionary *mode;
	unsigned int modeIndex, modeCount, bestModeIndex;
	int verbose;
	//	cvar_t *cMinFreq, *cMaxFreq;
	int minFreq, maxFreq;
	unsigned int colorDepth;
    
	verbose = 0;

	colorDepth = 32;

	minFreq = r_minDisplayRefresh.GetInteger();
	maxFreq = r_maxDisplayRefresh.GetInteger();
	if ( minFreq > maxFreq ) {
		common->Error( "r_minDisplayRefresh must be less than or equal to r_maxDisplayRefresh" );
	}
    
	displayModes = (NSArray *)CGDisplayAvailableModes(glw_state.display);
	if (!displayModes) {
		common->Error( "CGDisplayAvailableModes returned NULL -- 0x%0x is an invalid display", glw_state.display);
	}
    
	modeCount = [displayModes count];
	if (verbose) {
		common->Printf( "%d modes avaliable\n", modeCount);
		common->Printf( "Current mode is %s\n", [[(id)CGDisplayCurrentMode(glw_state.display) description] cStringUsingEncoding:NSUTF8StringEncoding]);
	}
    
	// Default to the current desktop mode
	bestModeIndex = 0xFFFFFFFF;
    
	for ( modeIndex = 0; modeIndex < modeCount; ++modeIndex ) {
		id object;
		int refresh;
        
		mode = [displayModes objectAtIndex: modeIndex];
		if (verbose) {
			common->Printf( " mode %d -- %s\n", modeIndex, [[mode description] cStringUsingEncoding:NSUTF8StringEncoding]);
		}

		// Make sure we get the right size
		if ([[mode objectForKey: (id)kCGDisplayWidth] intValue] != parms.width ||
				[[mode objectForKey: (id)kCGDisplayHeight] intValue] != parms.height) {
			if (verbose)
				common->Printf( " -- bad size\n");
			continue;
		}

		// Make sure that our frequency restrictions are observed
		refresh = [[mode objectForKey: (id)kCGDisplayRefreshRate] intValue];
		if (minFreq &&  refresh < minFreq) {
			if (verbose)
				common->Printf( " -- refresh too low\n");
			continue;
		}

		if (maxFreq && refresh > maxFreq) {
			if (verbose)
				common->Printf( " -- refresh too high\n");
			continue;
		}

		if ([[mode objectForKey: (id)kCGDisplayBitsPerPixel] intValue] != colorDepth) {
			if (verbose)
				common->Printf( " -- bad depth\n");
			continue;
		}

		object = [mode objectForKey: (id)kCGDisplayModeIsStretched];
		if ( object ) {
			if ( [object boolValue] != cvarSystem->GetCVarBool( "r_stretched" ) ) {
				if (verbose)
					common->Printf( " -- bad stretch setting\n");
				continue;
			}
		}
		else {
			if ( cvarSystem->GetCVarBool( "r_stretched" ) ) {
				if (verbose)
					common->Printf( " -- stretch requested, stretch property not available\n");
				continue;
			}
		}
		
		bestModeIndex = modeIndex;
		if (verbose)
			common->Printf( " -- OK\n");
	}

	if (verbose)
		common->Printf( " bestModeIndex = %d\n", bestModeIndex);

	if (bestModeIndex == 0xFFFFFFFF) {
		common->Printf( "No suitable display mode available.\n");
		return nil;
	}
    
	return [displayModes objectAtIndex: bestModeIndex];
}


#define MAX_DISPLAYS 128

void Sys_GetGammaTable(glwgamma_t *table) {
	CGTableCount tableSize = 512;
	CGDisplayErr err;
    
	table->tableSize = tableSize;
	if (table->red)
		free(table->red);
	table->red = (float *)malloc(tableSize * sizeof(*table->red));
	if (table->green)
		free(table->green);
	table->green = (float *)malloc(tableSize * sizeof(*table->green));
	if (table->blue)
		free(table->blue);
	table->blue = (float *)malloc(tableSize * sizeof(*table->blue));
    
	// TJW: We _could_ loop here if we get back the same size as our table, increasing the table size.
	err = CGGetDisplayTransferByTable(table->display, tableSize, table->red, table->green, table->blue,
																		&table->tableSize);
	if (err != CGDisplayNoErr) {
		common->Printf("GLimp_Init: CGGetDisplayTransferByTable returned %d.\n", err);
		table->tableSize = 0;
	}
}

void Sys_SetGammaTable(glwgamma_t *table) { }

void Sys_StoreGammaTables() {
	// Store the original gamma for all monitors so that we can fade and unfade them all
	CGDirectDisplayID displays[MAX_DISPLAYS];
	CGDisplayCount displayIndex;
	CGDisplayErr err;

	err = CGGetActiveDisplayList(MAX_DISPLAYS, displays, &glw_state.displayCount);
	if (err != CGDisplayNoErr)
		Sys_Error("Cannot get display list -- CGGetActiveDisplayList returned %d.\n", err);
    
	glw_state.originalDisplayGammaTables = (glwgamma_t *)calloc(glw_state.displayCount, sizeof(*glw_state.originalDisplayGammaTables));
	for (displayIndex = 0; displayIndex < glw_state.displayCount; displayIndex++) {
		glwgamma_t *table;

		table = &glw_state.originalDisplayGammaTables[displayIndex];
		table->display = displays[displayIndex];
		Sys_GetGammaTable(table);
	}
}


//  This isn't a mathematically correct fade, but we don't care that much.
void Sys_SetScreenFade(glwgamma_t *table, float fraction) {
	CGTableCount tableSize;
	CGGammaValue *red, *blue, *green;
	CGTableCount gammaIndex;
    
	//    if (!glConfig.deviceSupportsGamma)
	//        return;

	if (!(tableSize = table->tableSize))
		// we couldn't get the table for this display for some reason
		return;
    
	//    common->Printf("0x%08x %f\n", table->display, fraction);
    
	red = glw_state.tempTable.red;
	green = glw_state.tempTable.green;
	blue = glw_state.tempTable.blue;
	if (glw_state.tempTable.tableSize < tableSize) {
		glw_state.tempTable.tableSize = tableSize;
		red = (float *)realloc(red, sizeof(*red) * tableSize);
		green = (float *)realloc(green, sizeof(*green) * tableSize);
		blue = (float *)realloc(blue, sizeof(*blue) * tableSize);
		glw_state.tempTable.red = red;
		glw_state.tempTable.green = green;
		glw_state.tempTable.blue = blue;
	}

	for (gammaIndex = 0; gammaIndex < table->tableSize; gammaIndex++) {
		red[gammaIndex] = table->red[gammaIndex] * fraction;
		blue[gammaIndex] = table->blue[gammaIndex] * fraction;
		green[gammaIndex] = table->green[gammaIndex] * fraction;
	}
    
	CGSetDisplayTransferByTable(table->display, table->tableSize, red, green, blue);
}

// Fades all the active displays at the same time.

#define FADE_DURATION 0.5
void Sys_FadeScreens() {
	CGDisplayCount displayIndex;
	glwgamma_t *table;
	NSTimeInterval start, current;
	float time;
    
	//   if (!glConfig.deviceSupportsGamma)
	//        return;

	common->Printf("Fading all displays\n");
    
	start = [NSDate timeIntervalSinceReferenceDate];
	time = 0.0;
	while (time != FADE_DURATION) {
		current = [NSDate timeIntervalSinceReferenceDate];
		time = current - start;
		if (time > FADE_DURATION)
			time = FADE_DURATION;
            
		for (displayIndex = 0; displayIndex < glw_state.displayCount; displayIndex++) {            
			table = &glw_state.originalDisplayGammaTables[displayIndex];
			Sys_SetScreenFade(table, 1.0 - time / FADE_DURATION);
		}
	}
}

void Sys_FadeScreen(CGDirectDisplayID display) {
	CGDisplayCount displayIndex;
	glwgamma_t *table;

	common->Printf( "FIXME: Sys_FadeScreen\n" );
    
	return;
    
	//    if (!glConfig.deviceSupportsGamma)
	//        return;

	common->Printf("Fading display 0x%08x\n", display);

	for (displayIndex = 0; displayIndex < glw_state.displayCount; displayIndex++) {
		if (display == glw_state.originalDisplayGammaTables[displayIndex].display) {
			NSTimeInterval start, current;
			float time;
            
			start = [NSDate timeIntervalSinceReferenceDate];
			time = 0.0;

			table = &glw_state.originalDisplayGammaTables[displayIndex];
			while (time != FADE_DURATION) {
				current = [NSDate timeIntervalSinceReferenceDate];
				time = current - start;
				if (time > FADE_DURATION)
					time = FADE_DURATION;

				Sys_SetScreenFade(table, 1.0 - time / FADE_DURATION);
			}
			return;
		}
	}

	common->Printf("Unable to find display to fade it\n");
}

void Sys_UnfadeScreens() {
	CGDisplayCount displayIndex;
	glwgamma_t *table;
	NSTimeInterval start, current;
	float time;

	common->Printf( "FIXME: Sys_UnfadeScreens\n" );
    
	return;
    
	//    if (!glConfig.deviceSupportsGamma)
	//        return;
        
	common->Printf("Unfading all displays\n");

	start = [NSDate timeIntervalSinceReferenceDate];
	time = 0.0;
	while (time != FADE_DURATION) {
		current = [NSDate timeIntervalSinceReferenceDate];
		time = current - start;
		if (time > FADE_DURATION)
			time = FADE_DURATION;
            
		for (displayIndex = 0; displayIndex < glw_state.displayCount; displayIndex++) {            
			table = &glw_state.originalDisplayGammaTables[displayIndex];
			Sys_SetScreenFade(table, time / FADE_DURATION);
		}
	}
}

void Sys_UnfadeScreen(CGDirectDisplayID display, glwgamma_t *table) {
	CGDisplayCount displayIndex;
	
	common->Printf( "FIXME: Sys_UnfadeScreen\n" );

	return;
	//    if (!glConfig.deviceSupportsGamma)
	//        return;
    
	common->Printf("Unfading display 0x%08x\n", display);

	if (table) {
		CGTableCount i;
        
		common->Printf("Given table:\n");
		for (i = 0; i < table->tableSize; i++) {
			common->Printf("  %f %f %f\n", table->red[i], table->blue[i], table->green[i]);
		}
	}
    
	// Search for the original gamma table for the display
	if (!table) {
		for (displayIndex = 0; displayIndex < glw_state.displayCount; displayIndex++) {
			if (display == glw_state.originalDisplayGammaTables[displayIndex].display) {
				table = &glw_state.originalDisplayGammaTables[displayIndex];
				break;
			}
		}
	}
    
	if (table) {
		NSTimeInterval start, current;
		float time;
        
		start = [NSDate timeIntervalSinceReferenceDate];
		time = 0.0;

		while (time != FADE_DURATION) {
			current = [NSDate timeIntervalSinceReferenceDate];
			time = current - start;
			if (time > FADE_DURATION)
				time = FADE_DURATION;
			Sys_SetScreenFade(table, time / FADE_DURATION);
		}
		return;
	}
    
	common->Printf("Unable to find display to unfade it\n");
}

#define MAX_DISPLAYS 128

CGDirectDisplayID Sys_DisplayToUse(void) {
	static bool					gotDisplay =  NO;
	static CGDirectDisplayID	displayToUse;
    
	CGDisplayErr				err;
	CGDirectDisplayID			displays[MAX_DISPLAYS];
	CGDisplayCount				displayCount;
	int							displayIndex;
    
	if ( gotDisplay ) {
		return displayToUse;
	}
	gotDisplay = YES;    
    
	err = CGGetActiveDisplayList( MAX_DISPLAYS, displays, &displayCount );
	if ( err != CGDisplayNoErr ) {
		common->Error("Cannot get display list -- CGGetActiveDisplayList returned %d.\n", err );
	}

	// -1, the default, means to use the main screen
	displayIndex = r_screen.GetInteger();
        
	if ( displayIndex < 0 || displayIndex >= displayCount ) {
		// This is documented (in CGDirectDisplay.h) to be the main display.  We want to
		// return this instead of kCGDirectMainDisplay since this will allow us to compare
		// display IDs.
		displayToUse = displays[ 0 ];
	} else {
		displayToUse = displays[ displayIndex ];
	}

	return displayToUse;
}

/*
===================
GLimp_SetScreenParms
===================
*/
bool GLimp_SetScreenParms( glimpParms_t parms ) {
	return true;
}

/*
===================
Sys_GrabMouseCursor
===================
*/
void Sys_GrabMouseCursor( bool grabIt ) { }

