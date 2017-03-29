#include <iostream>
#include <string>
#include <stdio.h>
#include <cuda.h>
#include <fstream>

using namespace std;

#define TILE_WIDTH 16

__global__ void MatrixMulKernel(float *d_M, float *d_N, float *d_P,int width){
	__shared__ float Mds[TILE_WIDTH][TILE_WIDTH];
	__shared__ float Nds[TILE_WIDTH][TILE_WIDTH];

	int bx = blockIdx.x; int by = blockIdx.y;
	int tx = threadIdx.x; int ty = threadIdx.y;
	
	int row = by * TILE_WIDTH + ty;
	int col = bx * TILE_WIDTH + tx;

	float Pvalue = 0;

	for (int i = 0; i < width/TILE_WIDTH; ++i){

		Mds[ty][tx] = d_M[row*width + i*TILE_WIDTH + tx];
		Nds[ty][tx] =  d_N[(i*TILE_WIDTH + ty) *width + col];
		__syncthreads();

		for (int j = 0; j < TILE_WIDTH; ++j){
			Pvalue += Mds[ty][j] * Nds[j][tx];
		}
		__syncthreads();
	}
	d_P[row*width + col] = Pvalue;
}

int matrixMulHost(float *h_M, float *h_N, float *h_P, int width){
    int Pvalue;

    for(int row = 0; row < width ; ++row){
        for(int col = 0; col < width ; ++col){
            Pvalue = 0;
            for(int k = 0; k < width ; ++k){
                Pvalue += h_M[row*width+k] * h_N[k*width+col];
            }
            h_P[row*width+col] = Pvalue;
        }
    }
    return 0;
}

int initValues(float *data, int width){
    for(int i = 0; i < width*width; i++)
        data[i] = 2;
    return 0;
}

int printData(float *data, int width){
    for(int i = 0; i < width; ++i){
        for(int j = 0; j < width; ++j){
            printf("%f ", data[(i*width)+j]);
        }
        printf("\n");
    }
    return 0;
}

int main(int argc, char const *argv[])
{
	float *h_M, *h_N, *h_P,*h_P_d;
    float *d_M, *d_N,*d_P;
    std::string num = argv[1];
    int width = std::stoi(num);
    int size = width * width * sizeof(float);
    clock_t start, end, startGPU, endGPU;
    double cpu_time_used, gpu_time_used, aceleration;

   //for (int times = 0; times < 20; times++){
        h_M = (float*)malloc(size);
        h_N = (float*)malloc(size);
        h_P = (float*)malloc(size);
        h_P_d = (float*)malloc(size);

        initValues(h_M, width);
        initValues(h_N, width);

        printData(h_M, width);

        /////////Algoritmo Secuencial////////////////////////////////////////////
        start = clock();
        matrixMulHost(h_M, h_N, h_P, width);
        end = clock();
        cpu_time_used = ((double) (end - start)) / CLOCKS_PER_SEC;
        printf("Tiempo algoritmo secuencial: %.10f\n", cpu_time_used);
        /////////Algoritmo Secuencial/////////////////////////////////////////////

        cudaMalloc((void**)&d_M,size);
        cudaMalloc((void**)&d_N,size);
        cudaMalloc((void**)&d_P,size);
        //////////////////////Algoritmo Paralelo///////////////////////////
        startGPU = clock();
        cudaMemcpy(d_M, h_M, size, cudaMemcpyHostToDevice);
        cudaMemcpy(d_N, h_N, size, cudaMemcpyHostToDevice);

        int blockSize = 32;
        dim3 dimBlock(blockSize,blockSize,1);
        dim3 dimGrid(ceil(width/float(blockSize)),ceil(width/float(blockSize)),1);
        MatrixMulKernel<<<dimGrid,dimBlock>>>(d_M,d_N,d_P,width);
        cudaDeviceSynchronize();
        cudaMemcpy(h_P_d,d_P,size,cudaMemcpyDeviceToHost);
        endGPU = clock();
        gpu_time_used = ((double) (endGPU - startGPU)) / CLOCKS_PER_SEC;
        aceleration = cpu_time_used/gpu_time_used;

	    printf("%s \n","here i am");
        printData(h_P_d,width);

        printf("Tiempo algoritmo paralelo: %.10f\n", gpu_time_used);
        printf("La aceleración obtenida es de %.10fX\n",aceleration);

        std::string name =  "TimesMult.txt"+num;

        ofstream outfile(name,ios::binary | ios::app);
        outfile << gpu_time_used<<" "<< cpu_time_used <<" "<< aceleration << "\n";
        outfile.close();

        free(h_M);
        free(h_N);
        free(h_P);
        free(h_P_d);
        cudaFree(d_M);
        cudaFree(d_N);
        cudaFree(d_P);
    //}

	return 0;
}
