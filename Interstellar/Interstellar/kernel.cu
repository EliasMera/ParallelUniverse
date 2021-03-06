#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include <curand.h>
#include <stdio.h>
#include <stdlib.h>
#include <iostream>
#include <math.h>

#include "book.h"
#include "gl_helper.h"

#define MAXTHREADS 512u
#define WIDTH 512
#define HEIGHT 512

__device__
static const float G=1000.f, epsilon=0.1f;
__device__
float invsqrt(float x){
	long i;
	float x2, y;
	const float threehalfs = 1.5F;
	x2=x*0.5F;
	y=x;
	i=*(long*)&y;                // evil floating point bit level hacking
	i=0x5f3759df-(i>>1);         // what the fuck?
	y=*(float*)&i;
	y=y*(threehalfs-(x2*y*y));   // 1st iteration
    y=y*(threehalfs-(x2*y*y));   // 2nd iteration, this can be removed
	return y;
}
__device__
void set(float3 &u, const float x, const float y, const float z){
	u.x=x;
	u.y=y;
	u.z=z;
}
__device__
float magnitude2(const float3 &u){
	const float x=u.x;
	const float y=u.y;
	const float z=u.z;
    return x*x+y*y+z*z;
}
__device__
float3 distance(const float3 &p, const float3 &q){
	return make_float3(q.x-p.x, q.y-p.y, q.z-p.z);
}

__global__
void mapMagnitude2(float3 *d_vec, float *d_abs, const size_t n){
	int i=blockIdx.x*blockDim.x+threadIdx.x;
	if(i<n){
		d_abs[i]=magnitude2(d_vec[i]);
	}
}
__global__
void reduceMax(float *d_in, float *d_out, const size_t n){   
    extern __shared__ float shared[];
	int tid=threadIdx.x;
    int gid=blockIdx.x*blockDim.x+tid;
	shared[tid]= gid<n? d_in[gid]: -FLT_MAX;
    __syncthreads();
    for(unsigned int s=blockDim.x/2; s>0; s>>=1){
        if(tid<s){
            shared[tid]=__max(shared[tid], shared[tid+s]);
        }
        __syncthreads();
    }
    if(tid==0){
        d_out[blockIdx.x]=shared[0];
    }
}
__global__
void initialState(float* d_mass, float3 *d_pos, float3 *d_vel, float3 *d_acc, const int n){
	int i=blockIdx.x*blockDim.x+threadIdx.x;
	if(i<n){
		float radius=32+(64.0f*i)/n;
		float angle=16*(6.2832f*i)/n;
		float c=cos(angle);
		float s=sin(angle);
		float m=invsqrt(G*n/128.f);
		d_pos[i]=make_float3(radius*c+256, radius*s+256, 0.0f);
		d_vel[i]=make_float3(s/m, -c/m, 0.0f);
		d_acc[i]=make_float3(0.f, 0.f, 0.f);
		d_mass[i]=1.f;
	}
}
__global__
void interact(float *d_mass, float3 *d_pos, float3 *d_acc, const int n){
	extern __shared__ float3 s_acc[];
	int tid=threadIdx.x;
	int i=blockIdx.x;
	int j=blockIdx.y*blockDim.x+tid;
	if(j>=n || i==j){
		set(s_acc[tid], 0.f, 0.f, 0.f);
	}else{
		float3 r=distance(d_pos[i], d_pos[j]);
		float r2=magnitude2(r)+epsilon;
		float w2=G*d_mass[j]*invsqrt(r2*r2*r2);
		set(s_acc[tid], r.x*w2, r.y*w2, r.z*w2);
	}
	// Reduction
    __syncthreads();
    for(unsigned int s=blockDim.x/2; s>0; s>>=1){
        if(tid<s){
            s_acc[tid].x+=s_acc[tid+s].x;
			s_acc[tid].y+=s_acc[tid+s].y;
			s_acc[tid].z+=s_acc[tid+s].z;
        }
        __syncthreads();
    }
	if(tid==0){
		atomicAdd(&(d_acc[i].x), s_acc[0].x);
		atomicAdd(&(d_acc[i].y), s_acc[0].y);
		atomicAdd(&(d_acc[i].z), s_acc[0].z);
    }
}
__global__
void move(unsigned char *d_bitmap, float *mass, float3 *d_pos, float3 *d_vel, float3 *d_acc, float dt, const int n) {
	int i=blockIdx.x*blockDim.x+threadIdx.x;
	if(i<n){
		float vx=d_vel[i].x+d_acc[i].x*dt;
		float vy=d_vel[i].y+d_acc[i].y*dt;
		float vz=d_vel[i].z+d_acc[i].z*dt;
		d_pos[i].x+=vx*dt;
		d_pos[i].y+=vy*dt;
		d_pos[i].z+=vz*dt;
		set(d_vel[i], vx, vy, vz);
		set(d_acc[i], 0.f, 0.f, 0.f);

		int x=(int)d_pos[i].x;
		int y=(int)d_pos[i].y;
		if(x>=0 && x<WIDTH && y>=0 && y<HEIGHT){
			unsigned int m=255;
			int offset=WIDTH*y+x;
			d_bitmap[4*offset+0]=m;
			d_bitmap[4*offset+1]=m;
			d_bitmap[4*offset+2]=m;
			d_bitmap[4*offset+3]=255;
		}
	}
}

int divideCeil(int num, int den){
	return (num+den-1)/den;
}
unsigned int nextPowerOf2(unsigned int n){
  unsigned k=0;
  if(n&&!(n&(n-1))){
	  return n;
  }
  while(n!=0){
    n>>=1;
    k++;
  }
  return 1<<k;
}
float getMax(float *d_in, const size_t lenght){
	int n=lenght;
	int grid, block=MAXTHREADS;
	float *h_out=new float();
	do{
		grid=(n+block-1)/block;
		if(grid==1){
			block=nextPowerOf2(n);
		}
		reduceMax<<<grid, block, block*sizeof(float)>>>(d_in, d_in, n);
		n=grid;
	}while(grid>1);
	HANDLE_ERROR(cudaMemcpy(h_out, d_in, sizeof(float), cudaMemcpyDeviceToHost));
	return *h_out;
}
void randset(float* d_in, size_t n, float m, float s){
	curandGenerator_t generator;
	curandCreateGenerator(&generator, CURAND_RNG_PSEUDO_DEFAULT);
	curandGenerateNormal(generator, d_in, n, m, s);
	curandDestroyGenerator(generator);
}

struct CPUBitmap {
	unsigned char *pixels;
    int x, y;
	bool exit=false;

    void *dataBlock;
    void (*bitmapExit)(void*);

    CPUBitmap(int width, int height) {
		x=width;
        y=height;
		HANDLE_ERROR(cudaMallocHost((void**)&pixels, 4*width*height));
    }
    ~CPUBitmap() {
        delete[] pixels;
    }

    unsigned char* get_ptr( void ) const   { 
		return pixels; 
	}
    static CPUBitmap** get_bitmap_ptr(void) {
        static CPUBitmap *gBitmap;
        return &gBitmap;
    }
	long image_size( void ) const { 
		return 4*x*y; 
	}

	void display_and_exit(void(*e)(void*)=NULL){
        CPUBitmap** bitmap=get_bitmap_ptr();
        *bitmap=this;
        bitmapExit=e;
        // a bug in the Windows GLUT implementation prevents us from
        // passing zero arguments to glutInit()
        int c=1;
        char* dummy="";
        glutInit(&c, &dummy);
        glutInitDisplayMode(GLUT_SINGLE | GLUT_RGBA);
        glutInitWindowSize(x, y);
        glutCreateWindow("bitmap");
        glutDisplayFunc(Draw);
		//glutWindowStatusFunc();
        glutMainLoop();
    }
    
    // static method used for glut callbacks
    static void Close(void){
		CPUBitmap* bitmap=*(get_bitmap_ptr());
		bitmap->exit=true;
	}
	static void Draw(void){
		CPUBitmap* bitmap=*(get_bitmap_ptr());
		size_t size=bitmap->image_size();

		int n=1024;
		float dt, dvmax=4.0f;
		unsigned char *d_bitmap;
		float *d_mass, *d_aux;
		float3 *d_pos, *d_vel, *d_acc;

		HANDLE_ERROR(cudaMalloc((void**)&d_bitmap, size));
		HANDLE_ERROR(cudaMalloc((void**)&d_aux, n*sizeof(float)));
		HANDLE_ERROR(cudaMalloc((void**)&d_mass, n*sizeof(float)));
		HANDLE_ERROR(cudaMalloc((void**)&d_pos, n*sizeof(float3)));
		HANDLE_ERROR(cudaMalloc((void**)&d_vel, n*sizeof(float3)));
		HANDLE_ERROR(cudaMalloc((void**)&d_acc, n*sizeof(float3)));

		int block1D=MAXTHREADS;
		int grid1D=divideCeil(n, block1D);
		int bytes=block1D*sizeof(float3);
		dim3 block2D(MAXTHREADS);
		dim3 grid2D(n, divideCeil(n, MAXTHREADS));
		
		int memory=size+n*(3*sizeof(float3)+2*sizeof(float));
		printf("Currently using %d bytes of device global memory\n", memory);
		
		initialState<<<grid1D, block1D>>>(d_mass, d_pos, d_vel, d_acc, n);
		int i=0;
		do{
			HANDLE_ERROR(cudaMemsetAsync(d_bitmap, 0, size));
			interact<<<grid2D, block2D, bytes>>>(d_mass, d_pos, d_acc, n);

			mapMagnitude2<<<grid1D, block1D>>>(d_acc, d_aux, n);
			dt=dvmax/sqrt(getMax(d_aux, n));

			move<<<grid1D, block1D>>>(d_bitmap, d_mass, d_pos, d_vel, d_acc, dt, n);
			
			HANDLE_ERROR(cudaMemcpy(bitmap->pixels, d_bitmap, size, cudaMemcpyDeviceToHost));
			glDrawPixels(bitmap->x, bitmap->y, GL_RGBA, GL_UNSIGNED_BYTE, bitmap->pixels);
			glFlush();
			i++;
		}while(true);
    }
};

int main( void ) {
    CPUBitmap bitmap(WIDTH, HEIGHT);                              
    bitmap.display_and_exit();
}