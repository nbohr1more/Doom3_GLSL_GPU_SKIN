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

#include "../idlib/precompiled.h"
#pragma hdrstop

#include "tr_local.h"

/*
 ==============================================================================
 
 SHADER LOADING
 
 ==============================================================================
 */

static char				r_shaderDefines[4096];

static shader_t *		r_shaders[MAX_SHADERS];
static int				r_numShaders;

/*
 ==================
 R_PrintShaderInfoLog
 ==================
 */
static void R_PrintShaderInfoLog ( shader_t *shader ) {
    char	infoLog[4096];
    int		infoLogLen;
    
    qglGetShaderiv( shader->shaderId, GL_INFO_LOG_LENGTH, &infoLogLen );
    if(infoLogLen <= 1)
        return;
    
    qglGetShaderInfoLog( shader->shaderId, sizeof(infoLog), NULL, infoLog );
    
    common->Printf( "---------- Shader Info Log ----------\n" );
    common->Printf( "%s", infoLog );
    
    if( infoLogLen >= sizeof( infoLog ) )
        common->Printf( "...\n" );
    
    common->Printf( "-------------------------------------\n" );
}

/*
 ==================
 R_CompileShader
 ==================
 */
static void R_CompileShader ( shader_t *shader, const char *defines, const char *code ) {
    const char *source[2];
    
    switch ( shader->type ) {
        case GL_VERTEX_SHADER:
            common->DPrintf( "Compiling GLSL vertex shader '%s'...\n", shader->name );
            break;
        case GL_FRAGMENT_SHADER:
            common->DPrintf( "Compiling GLSL fragment shader '%s'...\n", shader->name );
            break;
    }
    
    // Create the shader
    shader->shaderId = qglCreateShader( shader->type );
    
    // Upload the shader source
    source[0] = defines;
    source[1] = code;
    
    qglShaderSource( shader->shaderId, 2, source, NULL );
    
    // Compile the shader
    qglCompileShader( shader->shaderId );
    
    // if an info log is available, print it to the console
    R_PrintShaderInfoLog( shader );
    
    // check if the compile was successful
    qglGetShaderiv( shader->shaderId, GL_COMPILE_STATUS, (GLint*)&shader->compiled );
    if (!shader->compiled){
        switch (shader->type){
            case GL_VERTEX_SHADER:
                common->Printf( S_COLOR_RED "Failed to compile vertex shader '%s'\n", shader->name );
                break;
            case GL_FRAGMENT_SHADER:
                common->Printf( S_COLOR_RED "Failed to compile fragment shader '%s'\n", shader->name );
                break;
        }
        
        return;
    }
}

/*
 ==================
 R_LoadShader
 ==================
 */
static shader_t *R_LoadShader ( const char *name, GLenum type, char *code ) {
    shader_t	*shader;
    
    if ( !glConfig.isInitialized )
        return NULL;
    
    if ( r_numShaders == MAX_SHADERS )
        common->Error( "R_LoadShader: MAX_SHADER hit" );
    
    r_shaders[r_numShaders++] = shader = (shader_t *)malloc(sizeof(shader_t));
    
    // Fill it in
    strncpy(shader->name, name, sizeof(shader->name));
    shader->type = type;
    shader->references = 0;
    
    R_CompileShader( shader, r_shaderDefines, code );
    
    return shader;
}

/*
 ==================
 R_FindShader
 ==================
 */
shader_t *R_FindShader ( const char *name, GLenum type ) {
    shader_t	*shader;
    char		*code;
    idStr       fullPath = "gl2progs/";
    fullPath += name;
    
    switch ( type ) {
        case GL_VERTEX_SHADER:
            fullPath += ".vs";
            break;
        case GL_FRAGMENT_SHADER:
            fullPath += ".fs";
            break;
    }
    
    if ( !name || !name[0] )
        return NULL;
    
    // load it from disk
    common->Printf( "%s", fullPath.c_str() );
    
    fileSystem->ReadFile( fullPath, (void **)&code, NULL );
    if ( !code ) {
        common->Printf( ": File not found\n" );
        return NULL;
    }
    
    common->Printf( "\n" );
    
    // load the shader
    shader = R_LoadShader( name, type, code );
    
    fileSystem->FreeFile( code );
    
    if ( !shader->compiled )
        return NULL;
    
    return shader;
}

//========================================================

/*
 ==================
 R_InitShaders
 ==================
 */
void R_InitShaders (void) {
    // build defines string
    strncpy( r_shaderDefines, "#version 120" "\n", sizeof(r_shaderDefines) );
}

/*
 ==================
 R_ShutdownShaders
 ==================
 */
void R_ShutdownShaders (void) {
    shader_t	*shader;
    int			i;

    // delete all the shaders
    for (i = 0; i < r_numShaders; i++){
        shader = r_shaders[i];
        
        qglDeleteShader(shader->shaderId);
    }
    
    // clear shaders list
    memset(r_shaders, 0, sizeof(r_shaders));
    
    r_numShaders = 0;
}


/*
 ==============================================================================
 
 PROGRAM LOADING
 
 ==============================================================================
 */

typedef struct {
    const char *		name;
    
    uniformType_t		type;
    int					size;
    uint				format;
} uniformTable_t;

// table of custom glsl uniforms
static uniformTable_t	r_uniformTable[] = {
    {"u_ClipPlane",			UT_CLIP_PLANE,				1,	GL_FLOAT_VEC4},
    {"u_ViewOrigin",		UT_VIEW_ORIGIN,				1,	GL_FLOAT_VEC3},
    {"u_ViewAxis",			UT_VIEW_AXIS,				1,	GL_FLOAT_MAT3},
    {"u_EntityOrigin",		UT_ENTITY_ORIGIN,			1,	GL_FLOAT_VEC3},
    {"u_EntityAxis",		UT_ENTITY_AXIS,				1,	GL_FLOAT_MAT3},
    {"u_SunOrigin",			UT_SUN_ORIGIN,				1,	GL_FLOAT_VEC3},
    {"u_SunDirection",		UT_SUN_DIRECTION,			1,	GL_FLOAT_VEC3},
    {"u_SunColor",			UT_SUN_COLOR,				1,	GL_FLOAT_VEC3},
    {"u_ScreenMatrix",		UT_SCREEN_MATRIX,			1,	GL_FLOAT_MAT4},
    {"u_CoordScaleAndBias",	UT_COORD_SCALE_AND_BIAS,	1,	GL_FLOAT_VEC4},
    {"u_ColorScaleAndBias",	UT_COLOR_SCALE_AND_BIAS,	1,	GL_FLOAT_VEC2},
    {NULL,					UT_CUSTOM,					0,	0}
};

static shaderProgram_t *r_programs[MAX_PROGRAMS];
static int				r_numPrograms;

/*
 ==================
 R_PrintProgramInfoLog
 ==================
 */
static void R_PrintProgramInfoLog( shaderProgram_t *program ) {
    
    char	infoLog[4096];
    int		infoLogLen;
    
    qglGetProgramiv( program->program, GL_INFO_LOG_LENGTH, &infoLogLen );
    if (infoLogLen <= 1)
        return;
    
    qglGetProgramInfoLog( program->program, sizeof(infoLog), NULL, infoLog );
    
    common->DPrintf( "---------- Program Info Log ----------\n" );
    common->DPrintf( "%s", infoLog );
    
    if ( infoLogLen >= sizeof(infoLog) )
        common->DPrintf( "...\n" );
    
    common->DPrintf( "--------------------------------------\n" );
}

/*
 ==================
 R_ParseProgramVertexAttribs
 ==================
 */
static void R_ParseProgramVertexAttribs( shaderProgram_t *shaderProgram ) {
    if ( qglGetAttribLocation( shaderProgram->program, "attr_TexCoord" ) == GLVA_TEXCOORD )
        shaderProgram->vertexAttribs |= VA_TEXCOORD;
    
    if ( qglGetAttribLocation( shaderProgram->program, "attr_Tangent" ) == GLVA_TANGENT )
        shaderProgram->vertexAttribs |= VA_TANGENT;
    
    if ( qglGetAttribLocation( shaderProgram->program, "attr_Bitangent" ) == GLVA_BITANGENT )
        shaderProgram->vertexAttribs |= VA_BITANGENT;
    
    if ( qglGetAttribLocation( shaderProgram->program, "attr_Normal" ) == GLVA_NORMAL )
        shaderProgram->vertexAttribs |= VA_NORMAL;
}

/*
 ==================
 R_ParseProgramUniforms
 ==================
 */
static void R_ParseProgramUniforms ( shaderProgram_t *shaderProgram ) {
    uniformTable_t	*uniformTable;
    uniform_t		*uniform, uniforms[MAX_PROGRAM_UNIFORMS];
    int				numUniforms;
    char			name[MAX_UNIFORM_NAME_LENGTH];
    uint			format;
    int				length, size;
    int				location;
    int				i;
    
    // get active uniforms
    qglGetProgramiv( shaderProgram->program, GL_ACTIVE_UNIFORMS, &numUniforms );
    if ( !numUniforms )
        return;
    
    for ( i = 0; i < numUniforms; i++ ) {
        qglGetActiveUniform( shaderProgram->program, i, sizeof(name), &length, &size, &format, name );
        
        location = qglGetUniformLocation( shaderProgram->program, name );
        if ( location == -1 )
            continue; // ignore built-in uniforms
        
        // fix up uniform array names
        if ( name[length-3] == '[' && name[length-2] == '0' && name[length-1] == ']' )
            name[length-3] = 0;
        
        // check for a predefined uniform name
        for ( uniformTable = r_uniformTable; uniformTable->name; uniformTable++ ) {
            if ( !strcmp( uniformTable->name, name ) )
                break;
        }
        
        if ( uniformTable->type != UT_CUSTOM ) {
            // check the size
            if ( uniformTable->size != size )
                common->Error( "R_ParseProgramUniforms: uniform '%s' in program has wrong size", name );
            
            // check the format
            if (uniformTable->format != format)
                common->Error( "R_ParseProgramUniforms: uniform '%s' in program has wrong format", name );
        }
        
        // add a new uniform
        if ( shaderProgram->numUniforms == MAX_PROGRAM_UNIFORMS )
            common->Error( "R_ParseProgramUniforms: MAX_PROGRAM_UNIFORMS hit" );
        
        uniform = &uniforms[shaderProgram->numUniforms++];
        
        strncpy( uniform->name, name, sizeof(uniform->name) );
        uniform->type = uniformTable->type;
        uniform->size = size;
        uniform->format = format;
        uniform->location = location;
        uniform->unit = -1;
        uniform->values[0] = 0.0f;
        uniform->values[1] = 0.0f;
        uniform->values[2] = 0.0f;
        uniform->values[3] = 0.0f;
    }
    
    // copy the uniforms
    shaderProgram->uniforms = (uniform_t *)malloc( shaderProgram->numUniforms * sizeof(uniform_t) );
    memcpy( shaderProgram->uniforms, uniforms, shaderProgram->numUniforms * sizeof(uniform_t) );
}


/*
 =================
 R_LinkProgram
 
 links the GLSL vertex and fragment shaders together to form a GLSL program
 =================
 */
static void R_LinkProgram( shaderProgram_t *shaderProgram ) {
    // create shader program object
    shaderProgram->program = qglCreateProgram();
    
    // attach the vertex and fragment shaders
    qglAttachShader( shaderProgram->program, shaderProgram->vertexShader->shaderId );
    qglAttachShader( shaderProgram->program, shaderProgram->fragmentShader->shaderId );
    
    // bind vertex attributes
    qglBindAttribLocation( shaderProgram->program, GLVA_TEXCOORD, "attr_TexCoord" );
    qglBindAttribLocation( shaderProgram->program, GLVA_TANGENT, "attr_Tangent" );
    qglBindAttribLocation( shaderProgram->program, GLVA_BITANGENT, "attr_Bitangent" );
    qglBindAttribLocation( shaderProgram->program, GLVA_NORMAL, "attr_Normal" );
    
    // link into a shader program
    qglLinkProgram( shaderProgram->program );
    
    // if an info log is available, print it to the console
    R_PrintProgramInfoLog( shaderProgram );
    
    // make sure we linked succesfully
    qglGetProgramiv( shaderProgram->program, GL_OBJECT_LINK_STATUS_ARB, (GLint*)&shaderProgram->linked );
    if( !shaderProgram->linked ) {
        common->Printf( S_COLOR_RED "R_LinkGLSLShader: program failed to link\n" );
        return;
    }
    
    // parse the active vertex attribs
    R_ParseProgramVertexAttribs( shaderProgram );
    
    // parse the active uniforms
    R_ParseProgramUniforms( shaderProgram );
}

/*
 ==================
 R_LoadProgram
 ==================
 */
static shaderProgram_t *R_LoadProgram ( const char *name, shader_t *vertexShader, shader_t *fragmentShader ) {
    shaderProgram_t	*program;
    
    if ( r_numPrograms == MAX_PROGRAMS )
        common->Error( "R_LoadProgram: MAX_PROGRAMS hit" );
    
    r_programs[r_numPrograms++] = program = (shaderProgram_t *)malloc(sizeof(shaderProgram_t));
    
    // fill it in
    strncpy( program->name, name, sizeof(program->name) );
    program->vertexShader = vertexShader;
    program->fragmentShader = fragmentShader;
    program->vertexAttribs = 0;
    program->numUniforms = 0;
    program->uniforms = NULL;
    
    R_LinkProgram( program );
    
    return program;
}

/*
 ==================
 R_FindProgram
 ==================
 */
shaderProgram_t *R_FindProgram ( const char *name, shader_t *vertexShader, shader_t *fragmentShader ) {
    shaderProgram_t	*program;
    
    if ( !vertexShader || !fragmentShader )
        common->Error( "R_FindProgram: NULL shader" );
    
    if ( !name || !name[0] )
        name = va("%s & %s", vertexShader->name, fragmentShader->name);
    
    // Load the program
    program = R_LoadProgram( name, vertexShader, fragmentShader );
    
    if ( !program->linked )
        return NULL;
    
    return program;
}

//==================================================

/*
 ==================
 R_InitPrograms
 ==================
 */
void R_InitPrograms (void) {
    
}

/*
 ==================
 R_ShutdownPrograms
 ==================
 */
void R_ShutdownPrograms (void) {
    shaderProgram_t	*program;
    int			i;
    
    // delete all the programs
    qglUseProgram(0);
    
    for (i = 0; i < r_numPrograms; i++){
        program = r_programs[i];
        
        qglDetachShader( program->program, program->vertexShader->shaderId );
        qglDetachShader( program->program, program->fragmentShader->shaderId );
        
        qglDeleteProgram( program->program );
    }
    
    // clear programs list
    memset( r_programs, 0, sizeof(r_programs) );
    
    r_numPrograms = 0;
}

/*
 ==============================================================================
 
 PROGRAM UNIFORMS & SAMPLERS
 
 ==============================================================================
 */


/*
 ==================
 R_GetProgramUniform
 ==================
 */
uniform_t *R_GetProgramUniform (shaderProgram_t *program, const char *name){
    
    uniform_t	*uniform;
    int			i;
    
    for (i = 0, uniform = program->uniforms; i < program->numUniforms; i++, uniform++){
        if (!strcmp(uniform->name, name))
            return uniform;
    }
    
    return NULL;
}

/*
 ==================
 R_GetProgramUniformExplicit
 ==================
 */
uniform_t *R_GetProgramUniformExplicit (shaderProgram_t *program, const char *name, int size, uint format){
    
    uniform_t	*uniform;
    int			i;
    
    for (i = 0, uniform = program->uniforms; i < program->numUniforms; i++, uniform++){
        if (uniform->size != size || uniform->format != format)
            continue;
        
        if (!strcmp(uniform->name, name))
            return uniform;
    }
    
    common->Error( "R_GetProgramUniformExplicit: couldn't find uniform '%s' in program '%s'", name, program->name );
    
    return NULL;
}

/*
 ==================
 R_SetProgramSampler
 ==================
 */
void R_SetProgramSampler (shaderProgram_t *program, uniform_t *uniform, int unit){
    
    if (uniform->unit == unit)
        return;
    uniform->unit = unit;
    
    GL_BindProgram(program);
    qglUniform1i(uniform->location, uniform->unit);
    GL_BindProgram(NULL);
}

/*
 ==================
 R_SetProgramSamplerExplicit
 ==================
 */
void R_SetProgramSamplerExplicit (shaderProgram_t *program, const char *name, int size, uint format, int unit){
    
    uniform_t	*uniform;
    int			i;
    
    for (i = 0, uniform = program->uniforms; i < program->numUniforms; i++, uniform++){
        if (uniform->size != size || uniform->format != format)
            continue;
        
        if (!strcmp(uniform->name, name))
            break;
    }
    
    if (i == program->numUniforms)
        common->Error( "R_SetProgramSamplerExplicit: couldn't find sampler '%s' in program '%s'", name, program->name );
    
    if (uniform->unit == unit)
        return;
    uniform->unit = unit;
    
    GL_BindProgram(program);
    qglUniform1i(uniform->location, uniform->unit);
    GL_BindProgram(NULL);
}


/*
 ==============================================================================
 
 UNIFORM UPDATES
 
 ==============================================================================
 */


/*
 ==================
 R_UniformFloat
 ==================
 */
void R_UniformFloat (uniform_t *uniform, float v0){
    
    if (uniform->values[0] == v0)
        return;
    
    uniform->values[0] = v0;
    
    qglUniform1f(uniform->location, v0);
}

/*
 ==================
 R_UniformFloat2
 ==================
 */
void R_UniformFloat2 (uniform_t *uniform, float v0, float v1){
    
    if (uniform->values[0] == v0 && uniform->values[1] == v1)
        return;
    
    uniform->values[0] = v0;
    uniform->values[1] = v1;
    
    qglUniform2f(uniform->location, v0, v1);
}

/*
 ==================
 R_UniformFloat3
 ==================
 */
void R_UniformFloat3 (uniform_t *uniform, float v0, float v1, float v2){
    
    if (uniform->values[0] == v0 && uniform->values[1] == v1 && uniform->values[2] == v2)
        return;
    
    uniform->values[0] = v0;
    uniform->values[1] = v1;
    uniform->values[2] = v2;
    
    qglUniform3f(uniform->location, v0, v1, v2);
}

/*
 ==================
 R_UniformFloat4
 ==================
 */
void R_UniformFloat4 (uniform_t *uniform, float v0, float v1, float v2, float v3){
    
    if (uniform->values[0] == v0 && uniform->values[1] == v1 && uniform->values[2] == v2 && uniform->values[3] == v3)
        return;
    
    uniform->values[0] = v0;
    uniform->values[1] = v1;
    uniform->values[2] = v2;
    uniform->values[3] = v3;
    
    qglUniform4f(uniform->location, v0, v1, v2, v3);
}

/*
 ==================
 R_UniformFloatArray
 ==================
 */
void R_UniformFloatArray (uniform_t *uniform, int count, const float *v){
    
    uniform->values[0] = 0.0f;
    
    qglUniform1fv(uniform->location, count, v);
}

/*
 ==================
 R_UniformVector2
 ==================
 */
void R_UniformVector2 (uniform_t *uniform, const idVec2 &v){
    
    if (uniform->values[0] == v[0] && uniform->values[1] == v[1])
        return;
    
    uniform->values[0] = v[0];
    uniform->values[1] = v[1];
    
    qglUniform2fv(uniform->location, 1, v.ToFloatPtr());
}

/*
 ==================
 R_UniformVector2Array
 ==================
 */
void R_UniformVector2Array (uniform_t *uniform, int count, const idVec2 *v){
    
    uniform->values[0] = 0.0f;
    uniform->values[1] = 0.0f;
    
    qglUniform2fv(uniform->location, count, v->ToFloatPtr());
}

/*
 ==================
 R_UniformVector3
 ==================
 */
void R_UniformVector3 (uniform_t *uniform, const idVec3 &v){
    
    if (uniform->values[0] == v[0] && uniform->values[1] == v[1] && uniform->values[2] == v[2])
        return;
    
    uniform->values[0] = v[0];
    uniform->values[1] = v[1];
    uniform->values[2] = v[2];
    
    qglUniform3fv(uniform->location, 1, v.ToFloatPtr());
}

/*
 ==================
 R_UniformVector3Array
 ==================
 */
void R_UniformVector3Array (uniform_t *uniform, int count, const idVec3 *v){
    
    uniform->values[0] = 0.0f;
    uniform->values[1] = 0.0f;
    uniform->values[2] = 0.0f;
    
    qglUniform3fv(uniform->location, count, v->ToFloatPtr());
}

/*
 ==================
 R_UniformVector4
 ==================
 */
void R_UniformVector4 (uniform_t *uniform, const idVec4 &v){
    
    if (uniform->values[0] == v[0] && uniform->values[1] == v[1] && uniform->values[2] == v[2] && uniform->values[3] == v[3])
        return;
    
    uniform->values[0] = v[0];
    uniform->values[1] = v[1];
    uniform->values[2] = v[2];
    uniform->values[3] = v[3];
    
    qglUniform4fv(uniform->location, 1, v.ToFloatPtr());
}

/*
 ==================
 R_UniformVector4Array
 ==================
 */
void R_UniformVector4Array (uniform_t *uniform, int count, const idVec4 *v){
    
    uniform->values[0] = 0.0f;
    uniform->values[1] = 0.0f;
    uniform->values[2] = 0.0f;
    uniform->values[3] = 0.0f;
    
    qglUniform4fv(uniform->location, count, v->ToFloatPtr());
}

/*
 ==================
 R_UniformMatrix3
 ==================
 */
void R_UniformMatrix3 (uniform_t *uniform, const idMat3 &m){
    
    qglUniformMatrix3fv(uniform->location, 1, GL_TRUE, m.ToFloatPtr());
}

/*
 ==================
 R_UniformMatrix3Array
 ==================
 */
void R_UniformMatrix3Array (uniform_t *uniform, int count, const idMat3 *m){
    
    qglUniformMatrix3fv(uniform->location, count, GL_TRUE, m->ToFloatPtr());
}

/*
 ==================
 R_UniformMatrix4
 ==================
 */
void R_UniformMatrix4 (uniform_t *uniform, const idMat4 &m){
    
    qglUniformMatrix4fv(uniform->location, 1, GL_TRUE, m.ToFloatPtr());
}

/*
 ==================
 R_UniformMatrix4Array
 ==================
 */
void R_UniformMatrix4Array (uniform_t *uniform, int count, const idMat4 *m){
    
    qglUniformMatrix4fv(uniform->location, count, GL_TRUE, m->ToFloatPtr());
}
